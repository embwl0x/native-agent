import Foundation
import ApprovalInbox
import ChatTurnRuntime
import ChatTurnContracts
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import NativeAgentShared
import DeviceSync
import Transcripts
// Blueprint: | `AttentionRouter+HeldDelivery.swift` | Checked current-format held-intent admission, immutable ledger release and signed phone settlement; no inbox delivery-state writes or snapshot replay |

extension AttentionRouter {
    public static func holdsMacBanner(_ importance: AttentionImportance, dataRoot: URL = PersistenceCore.defaultDataRoot(), at date: Date = Date()) -> Bool {
        honorsQuietHours(importance) && inQuietHours(at: date, dataRoot: dataRoot)
    }

    public static func holdsResidentWake(session: String?, dataRoot: URL, at date: Date = Date()) -> Bool {
        TurnQuietHoursWindow.holdsResidentWake(session: session ?? ChatToolSessionContext.verifiedSessionId, dataRoot: dataRoot, at: date)
    }

    nonisolated static func heldImportKey(_ value: JSONValue) throws -> String {
        guard let row = value.objectValue, let id = row["id"]?.stringValue else { throw CocoaError(.fileReadCorruptFile) }
        var intent = row.filter { $0.key.hasPrefix("held_") }
        intent["id"] = .string(id)
        intent["title"] = row["title"]; intent["summary"] = row["summary"]
        intent["revision"] = .string(try LiveNotificationInbox.notificationRevision(value)); intent["created_at"] = row["created_at"]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return NotificationOccurrence.digest(try encoder.encode(intent))
    }

    public static func hasHeld(dataRoot: URL) async throws -> Bool {
        let state = try NotificationDeliveryLedger(dataRoot: dataRoot).read()
        if state.entries.values.contains(where: { $0.supersededBy == nil && $0.rows.values.contains { $0.outcome.mayAttempt } }) { return true }
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        var gap: Error?
        for read in try await inbox.cardReads() {
            do {
                let item = try read.get()
                if let row = try await inbox.row(id: item.id), row.objectValue?["held_delivery"] != nil,
                   state.imported[try heldImportKey(row)] == nil { return true }
            } catch { gap = error }
        }
        if let gap { throw gap }
        return false
    }

    /// A release imports source intents once, then reads only the current ledger
    /// and obtains each send's claim under its lock. It never acknowledges an
    /// old inbox snapshot, and it never rewrites the watched inbox.
    public static func releaseHeld(dataRoot: URL, router: AttentionRouter) async throws -> Int {
        var failures = try await router.importHeldIntents()
        let confirmed = try iCloudBridge.phoneConfirmedEventIDs(dataRoot: dataRoot)
        try await settleKnocks(confirmed: confirmed, dataRoot: dataRoot)
        let ledger = NotificationDeliveryLedger(dataRoot: dataRoot)
        let snapshot = try ledger.read()
        var released = 0
        for entry in snapshot.entries.values where entry.supersededBy == nil {
            guard !Task.isCancelled else { break }
            let occurrence = entry.occurrence
            do {
                try await router.settlePreferences(occurrence)
                guard entry.rows.values.contains(where: { $0.outcome.mayAttempt }) else { continue }
                if let card = occurrence.cardID {
                    guard let row = try await LiveNotificationInbox.live(dataRoot: dataRoot).row(id: card)?.objectValue else {
                        throw ToolFailureError("The notification card is missing; its delivery intent remains owed until its source is reconciled.", effects: .none, owner: LiveNotificationInbox.livePath(dataRoot: dataRoot).path)
                    }
                    guard occurrence.sourceRevision == (try LiveNotificationInbox.notificationRevision(.object(row))) else {
                        throw ToolFailureError("The card changed; the older occurrence cannot dispatch its saved payload. Its current source must retain the new intent.", effects: .none, owner: LiveNotificationInbox.livePath(dataRoot: dataRoot).path)
                    }
                    if row["status"] == .string("archived") || row["status"] == .string("dismissed") { continue }
                    if let approval = row["approval_id"]?.stringValue ?? row["related_approval_id"]?.stringValue,
                       try await SwiftNativeApprovalInbox(root: dataRoot).get(approval).status != "pending" { continue }
                }
                if occurrence.honorsQuietHours, try TurnQuietHoursWindow.checkedRead(dataRoot: dataRoot)?
                    .contains(hour: Calendar.current.component(.hour, from: Date())) == true { continue }
                let result = try await router.dispatch(occurrence.id)
                let updated = try ledger.read().entries[occurrence.id]
                if updated?.rows.values.allSatisfy({ $0.outcome.settled }) == true { released += 1 }
                for (way, outcome) in result.destinationOutcomes {
                    if case .notDelivered(let reason) = outcome { failures.append(occurrence.id + " " + way + ": " + reason) }
                }
            } catch { failures.append(occurrence.id + ": " + error.localizedDescription) }
        }
        if !failures.isEmpty {
            throw ToolFailureError("Held delivery remains owed (\(released) settled): " + failures.joined(separator: "; "),
                effects: .unknown, owner: ledger.path.path, code: "held_delivery_unavailable",
                instruction: "Repair the named delivery source. Unknown sends require destination evidence before another attempt.", recovery: .reconcile)
        }
        return released
    }

    /// Current writers retain held_* as an intent on the canonical card. They
    /// are not delivery state. Consume each exact intent once under its source
    /// lock, including formats still written by interactions and triggers.
    private func importHeldIntents() async throws -> [String] {
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        let reads = try await inbox.cardReads()
        let root = dataRoot
        var failures: [String] = []
        for read in reads {
            do {
                let item = try read.get()
                try await SwiftNativePersistenceCore.withFileLock(inbox.path, waitingAtMost: 5) {
                    guard let value = try await inbox.row(id: item.id), let row = value.objectValue,
                          let rawWays = row["held_delivery"] else { return }
                    let key = try Self.heldImportKey(value)
                    let ledger = NotificationDeliveryLedger(dataRoot: root)
                    if try ledger.read().imported[key] != nil { return }
                    guard case .array(let ways) = rawWays else { throw CocoaError(.fileReadCorruptFile) }
                    if ways.isEmpty { return }
                    func text(_ key: String, default defaultValue: String? = nil) throws -> String {
                        if let value = row[key] {
                            guard let text = value.stringValue else { throw CocoaError(.fileReadCorruptFile) }; return text
                        }
                        guard let defaultValue else { throw CocoaError(.fileReadCorruptFile) }; return defaultValue
                    }
                    let title = try text("held_title", default: item.title)
                    let body = try text("held_body", default: item.summary)
                    let approval = row["approval_id"]?.stringValue
                    let event = try text("held_event_id", default: approval.map { "approval:" + $0 } ?? item.id)
                    let reason = try text("held_reason", default: event)
                    let rawImportance = try text("held_importance", default: AttentionImportance.ownerWaiting.rawValue)
                    guard let importance = AttentionImportance(rawValue: rawImportance) else { throw CocoaError(.fileReadCorruptFile) }
                    let originData = try row["held_origin"].map { try $0.serializedData(pretty: false) }
                    let origin = try originData.map { try JSONDecoder().decode(AttentionOrigin.self, from: $0) }
                    let originEncoder = JSONEncoder(); originEncoder.outputFormatting = [.sortedKeys]
                    let canonicalOrigin = try origin.map { try originEncoder.encode($0) }
                    let selected: AttentionDelivery
                    if row["held_pinned_to"] != nil {
                        guard let pinned = AttentionDelivery(rawValue: try text("held_pinned_to")) else { throw CocoaError(.fileReadCorruptFile) }; selected = pinned
                    } else { selected = Self.policy(importance: importance, origin: origin) }
                    var destinations: [String] = []
                    for way in ways {
                        guard let name = way.stringValue, name == "phone" || name == "mac" else { throw CocoaError(.fileReadCorruptFile) }
                        if name == "mac" { destinations.append(name) }
                        else if selected != .none { destinations.append(Self.destination(selected, origin: origin)) }
                    }
                    guard !destinations.isEmpty else { return }
                    let info: [String: String]
                    if let retained = row["held_user_info"] {
                        info = try JSONDecoder().decode([String: String].self, from: retained.serializedData(pretty: false))
                    } else if let approval { info = ["screen": "approvals", "source": "approval", "approvalId": approval] }
                    else { info = ["screen": "inbox", "itemId": item.id] }
                    let canonical = NativeAgentDeviceEventIdentity.notification(userInfo: info, fallback: event)
                    let quietPolicy: Bool
                    if let raw = row["held_honors_quiet_hours"] {
                        guard case .bool(let value) = raw else { throw CocoaError(.fileReadCorruptFile) }; quietPolicy = value
                    } else {
                        quietPolicy = row["held_pinned_to"] == nil ? Self.honorsQuietHours(importance)
                            : (ways.contains(.string("mac")) || row["source"] == .string("resident_wake"))
                    }
                    let occurrence = try NotificationOccurrence(eventID: canonical, cardID: item.id, title: title, body: body,
                        reason: reason, userInfo: info, importance: importance.rawValue, route: selected.rawValue,
                        origin: canonicalOrigin, soundName: row["held_sound_name"]?.stringValue, destinations: destinations,
                        sourceRevision: try LiveNotificationInbox.notificationRevision(value),
                        honorsQuietHours: quietPolicy)
                    let prior: NotificationDeliveryOutcome? = try Self.retainedReasons(dataRoot: root)[canonical] == Self.stableDigest(reason)
                        ? .unknown(sent: true, reason: "Retained reason-only receipt; destination unconfirmed") : nil
                    try await ledger.retain(occurrence, importKey: key, priorOutcome: prior)
                }
            } catch { failures.append(error.localizedDescription) }
        }
        return failures
    }
}
