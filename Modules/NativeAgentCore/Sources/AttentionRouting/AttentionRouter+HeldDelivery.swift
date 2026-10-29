import Foundation
import ApprovalInbox
import ChatTurnRuntime
import ChatTurnContracts
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import NativeAgentShared
import TelegramBot
import DeviceSync
import Experiences
import Transcripts
// Blueprint: | `AttentionRouter+HeldDelivery.swift` | `AttentionRouter` quiet-hour holding and per-destination release; banners settle independently and unknown sends remain held |

extension AttentionRouter {
    /// Mac banners obey class-decided quiet hours independently of the phone switch and push ledger.
    /// A delivered push does not prove that its banner posted.
    public static func holdsMacBanner(
        _ importance: AttentionImportance,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        at date: Date = Date()
    ) -> Bool {
        honorsQuietHours(importance) && inQuietHours(at: date, dataRoot: dataRoot)
    }

    // MARK: - Held for quiet hours

    /// Knocks from her resident wake wait through the person's quiet hours.
    public static func holdsResidentWake(session: String?, dataRoot: URL, at date: Date = Date()) -> Bool {
        TurnQuietHoursWindow.holdsResidentWake(session: session ?? ChatToolSessionContext.verifiedSessionId, dataRoot: dataRoot, at: date)
    }

    public static func hasHeld(dataRoot: URL) async -> Bool {
        let rows = (try? await LiveNotificationInbox.live(dataRoot: dataRoot).rows()) ?? []
        return rows.contains { if case .object(let row) = $0 { row["held_delivery"] != nil } else { false } }
    }

    /// Once quiet hours end, clear only destinations whose transport accepted
    /// the knock. Failed sends and unavailable approval reads remain held.
    public static func releaseHeld(dataRoot: URL, router: AttentionRouter,
                                   banner: @Sendable (String, String, [String: String], String?) async -> Bool) async -> Int {
        guard !inQuietHours(at: Date(), dataRoot: dataRoot) else { return 0 }
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        var released = 0
        for case .object(let row) in (try? await inbox.rows()) ?? [] {
            guard !Task.isCancelled else { break }
            guard case .array(let ways)? = row["held_delivery"], case .string(let id)? = row["id"] else { continue }
            let title = if case .string(let text)? = row["held_title"] ?? row["title"] { text } else { "" }
            let body = if case .string(let text)? = row["held_body"] ?? row["summary"] { text } else { "" }
            let userInfo: [String: String]
            do { userInfo = try row["held_user_info"].map { try JSONDecoder().decode([String: String].self, from: $0.serializedData(pretty: false)) } ?? [:] }
            catch { nativeLog("attention_router: held metadata unavailable: %@", error.localizedDescription); continue }
            // A card settled or an approval decided meanwhile is no longer news.
            let approval: String? = if case .string(let value)? = row["approval_id"] { value } else { nil }
            var live = row["status"] != .string("archived") && row["status"] != .string("dismissed")
            if live, let approval {
                do { live = try await SwiftNativeApprovalInbox(root: dataRoot).get(approval).status == "pending" }
                catch ApprovalInboxError.notFound { live = false }
                catch {
                    nativeLog("attention_router: held approval unavailable: %@", error.localizedDescription)
                    continue
                }
            }
            var remaining = live ? ways : []
            if live, ways.contains(.string("phone")) {
                do {
                    func retainedString(_ key: String) throws -> String? {
                        guard let value = row[key] else { return nil }
                        guard case .string(let text) = value else { throw CocoaError(.fileReadCorruptFile) }
                        return text
                    }
                    let eventID = try retainedString("held_event_id") ?? approval.map { "approval:\($0)" } ?? id
                    let reason = try retainedString("held_reason") ?? eventID
                    let importanceName = try retainedString("held_importance") ?? AttentionImportance.ownerWaiting.rawValue
                    let pinnedName = try retainedString("held_pinned_to")
                    let pinned = pinnedName.flatMap(AttentionDelivery.init(rawValue:))
                    guard let importance = AttentionImportance(rawValue: importanceName), pinnedName == nil || pinned != nil else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let origin = try row["held_origin"].map { try JSONDecoder().decode(AttentionOrigin.self, from: $0.serializedData(pretty: false)) }
                    let outcome = try await router.route(eventId: eventID, importance: importance, title: title, body: body,
                        reason: reason, userInfo: row["held_user_info"] != nil ? userInfo :
                            approval.map { ["screen": "approvals", "source": "approval", "approvalId": $0] } ?? ["screen": "inbox", "itemId": id],
                        origin: origin, pinnedTo: pinned)
                    if outcome.deliveryProjection.reachedAChannel || outcome.deliveryProjection == .previouslyHandled {
                        remaining.removeAll { $0 == .string("phone") }
                    }
                } catch { nativeLog("attention_router: held push failed: %@", error.localizedDescription) }
            }
            if live, !Task.isCancelled, ways.contains(.string("mac")) {
                let sound: String? = if case .string(let value)? = row["held_sound_name"] { value } else { nil }
                do {
                    if try await inbox.patch(id: id, unlessPresent: "held_mac_dispatch", ["held_mac_dispatch": .string("sent_unconfirmed")]) {
                        var posted = false
                        if !Task.isCancelled { posted = await banner(title, body, userInfo, sound) }
                        let dispatch: JSONValue = posted ? .string("completed") : .null
                        let dispatchSaved = await settle {
                            do { return try await inbox.patch(id: id, ["held_mac_dispatch": dispatch]) }
                            catch { nativeLog("attention_router: held banner settlement failed: %@", error.localizedDescription); return false }
                        }
                        if posted {
                            remaining.removeAll { $0 == .string("mac") }
                        } else if dispatchSaved {
                            nativeLog("attention_router: held banner failed")
                        }
                    } else if row["held_mac_dispatch"] == .string("completed") {
                        remaining.removeAll { $0 == .string("mac") }
                    }
                } catch { nativeLog("attention_router: held banner dispatch remains unconfirmed: %@", error.localizedDescription) }
            }
            guard remaining != ways else { continue }
            let retained = remaining
            let acknowledged = await settle {
                do { return try await inbox.patch(id: id, ["held_delivery": retained.isEmpty ? .null : .array(retained)]) }
                catch { nativeLog("attention_router: could not acknowledge held knock: %@", error.localizedDescription); return false }
            }
            if acknowledged && remaining.isEmpty { released += 1 }
        }
        return released
    }
}
