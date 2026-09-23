import Foundation
import CryptoKit
import PersistenceCore

/// A bounded last-action observation, never task completion or a history index.
struct AgentWorkspaceWorkReceipt: Sendable, Equatable, Codable {
    var title: String
    var status: String
    var readback: String
    var observedAt: Date

    var isValid: Bool {
        [title, status, readback].allSatisfy { !$0.isEmpty && $0.utf8.count <= 2048 && !$0.contains("\0") }
            && observedAt.timeIntervalSince1970.isFinite
    }
    var value: JSONValue {
        .object(["action": .string(title), "owner_outcome": .string(status), "readback": .string(readback),
                 "observed_at": .string(ISO8601DateFormatter().string(from: observedAt)),
                 "meaning": .string("Last observed action, not completion of the work's requirements.")])
    }
}

/// A work's navigation context, not a second task ledger or evidence store.
/// Notes are explicitly authored by the agent; references reopen canonical owners.
extension AgentWorkspaceNavigation {
    static func workReceiptKey(_ location: AgentWorkspaceLocation) -> String? {
        guard let identity = placeIdentity(location) else { return nil }
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func placeAction(_ location: AgentWorkspaceLocation, session: Session) -> JSONValue? {
        guard let key = workReceiptKey(location), let receipt = session.placeActions[key],
              case .object(var value) = receipt.value else { return nil }
        value["meaning"] = .string("Last observed action for this place, at the recorded time. This is not a new verification of its current contents or completion of the work's requirements.")
        return .object(value)
    }

    func focusWork(key: String) throws {
        guard var session = sessions[key] else { return }
        if session.focusedWork { session.focusedWork = false; sessions[key] = session; return }
        if session.keptPlaces.isEmpty, let document = session.document,
           let source = Self.keepablePlace(document.location, session: session) { session.keptPlaces = [source] }
        guard !session.keptPlaces.isEmpty else {
            throw DesktopFailure(message: "Open the work's file or keep a source first. Existing places were preserved.")
        }
        session.focusedWork = true
        session.places = session.keptPlaces
        session.path = [.home, .workOverview]
        if let anchor = session.workAnchor, !session.keptPlaces.contains(where: { Self.placeIdentity($0) == Self.placeIdentity(anchor) }) {
            session.workAnchor = nil; session.workTopic = nil
        }
        if let document = session.document, !session.keptPlaces.contains(where: { Self.placeIdentity($0) == Self.placeIdentity(document.location) }) {
            session.document = nil
        }
        session.arrivalReturn = nil
        session.workLinkNotice = nil
        session.arrivals?.monitor.invalidate()
        sessions[key] = session
    }

    func keepOpenedWorkSource(_ location: AgentWorkspaceLocation, value: JSONValue, key: String) {
        guard let session = sessions[key], session.focusedWork else { return }
        if value == .null { return }
        if case .object(let fields) = value {
            if fields["ok"] == .bool(false) || ["error", "error_code"].contains(where: { fields[$0] != nil && fields[$0] != .null }) { return }
            let refused: Set<String> = ["readback_unavailable", "failed", "error", "unavailable", "attention", "blocked", "blocked_by_trust", "denied", "record_changed", "file_changed", "outcome_unknown", "needs_setup", "reconnect_required", "session_unavailable", "no_outbound_route"]
            for field in ["status", "state"] {
                if case .string(let status)? = fields[field], refused.contains(status) { return }
            }
        }
        let isSource: Bool
        switch location {
        case .record(let tool, let input, _):
            switch tool {
            case "read_file", "read_page", "read_skill", "read_chat_message", "shelf_entry", "browser.chrome_snapshot": isSource = true
            case "recall_memory": isSource = input["memory_id"] != nil
            case "desk_read": isSource = input["handle"] != nil
            // Correspondence may be an unrelated interruption. Keep the window
            // for returning, but attach it to the work only on explicit Keep.
            case "chat_conversations", "mail_list_recent", "messages_recent_threads": isSource = false
            case "agent_read":
                if case .string(let agent)? = input["agent"] { isSource = agent.hasPrefix("bot:") || input["conversation"] != nil }
                else { isSource = false }
            default: isSource = false
            }
        default: isSource = false
        }
        guard isSource, let place = Self.keepablePlace(location, session: session) else { return }
        if case .browserBookmark(let url, _, _) = place,
           session.keptPlaces.contains(where: { if case .browserBookmark(let keptURL, _, _) = $0 { return keptURL == url }; return false }) { return }
        do { try keepWorkPlace(place, key: key) }
        catch { sessions[key]?.workLinkNotice = error.localizedDescription }
    }

    func recordWorkAction(tool: String, input: [String: JSONValue], title: String, receipt: JSONValue,
                          readback location: AgentWorkspaceLocation, value: JSONValue?, key: String) {
        guard let session = sessions[key], session.selectedWorkspaceID != nil || session.workNote != nil else { return }
        let owner: [String: JSONValue]
        if case .object(let fields) = receipt { owner = fields } else { return }
        let status: String
        if owner["ok"] == .bool(false) || ["error", "error_code"].contains(where: { owner[$0] != nil && owner[$0] != .null }) { status = "failed" }
        else if case .string(let text)? = owner["status"] ?? owner["state"], !text.isEmpty { status = text }
        else if owner["ok"] == .bool(true) { status = "ok" }
        else { status = "unknown" }
        var observation = "No separate current readback was returned."
        if tool == "agent_message", case .string(let reply)? = owner["reply"], !reply.isEmpty {
            observation = "The peer's reply returned in this conversation; it is not independent verification of its work."
        }
        if case .record = location, let value {
            observation = "Returned the current view of " + String(location.title.prefix(160)) + "."
            if case .record("bot_list", let arguments, _) = location,
               case .string(let id)? = arguments["id"], case .object(let result) = value,
               case .array(let bots)? = result["bots"],
               let bot = bots.first(where: { if case .object(let row) = $0 { return row["id"] == .string(id) }; return false }),
               case .object(let fields) = bot, case .string(let name)? = fields["name"] {
                observation = "Returned the current settings of " + String(name.prefix(160)) + "."
            }
            if case .object(let fields) = value,
               fields["status"] == .string("readback_unavailable") || fields["error"] != nil || fields["ok"] == .bool(false) {
                observation = "Current readback unavailable; the owner's action outcome is retained."
            } else if tool == "write_file", input["append"] != .bool(true), case .string(let expected)? = input["content"] {
                let actual: String?
                if case .string(let text) = value { actual = text }
                else if case .object(let fields) = value, fields["has_more"] != .bool(true), fields["truncated"] != .bool(true),
                        case .string(let text)? = fields["content"] { actual = text }
                else { actual = nil }
                if let actual {
                    observation = actual.utf8.elementsEqual(expected.utf8)
                        ? "The complete current file matches the submitted text."
                        : "The current file differs from the submitted text; reopen it before further changes."
                } else { observation = "The file was reopened, but a complete text comparison was unavailable." }
            }
        }
        let label = String(title.replacingOccurrences(of: "\0", with: "").prefix(160))
        let state = String(status.replacingOccurrences(of: "\0", with: "").prefix(160))
        let recorded = AgentWorkspaceWorkReceipt(title: label.isEmpty ? "Action" : label, status: state.isEmpty ? "unknown" : state,
            readback: observation.replacingOccurrences(of: "\0", with: ""), observedAt: Date())
        sessions[key]?.lastWorkAction = recorded
        // Bind from the action's owner target, never the view that happened to
        // be selected before dispatch. A conversation must not overwrite the
        // document it discusses. Unknown/failed attempts replace old success
        // for the same exact target, just as the overall last action does.
        var target = AgentWorkspaceEnvironment.readback(tool: tool, input: input)
        if tool == "agent_message", case .string(let agent)? = input["agent"] {
            var arguments: [String: JSONValue] = ["agent": .string(agent)]
            if agent.hasPrefix("bot:") {
                target = .record(tool: "agent_read", input: arguments, title: title)
            } else if case .string(let conversation)? = input["conversation"] ?? owner["conversation"], !conversation.isEmpty {
                arguments["conversation"] = .string(conversation)
                target = .record(tool: "agent_read", input: arguments, title: title)
            }
        } else if target == nil, value != nil, case .record = location {
            // Creation may only acquire its exact owner reference in readback.
            target = location
        }
        if case .record("browser.chrome_snapshot", let arguments, _)? = target, let value {
            // Navigation may have changed the URL on an existing lease. The
            // final observation belongs to the fresh owner snapshot, never its
            // previous lease-to-bookmark association.
            guard case .object(let page) = value, page["ok"] != .bool(false), page["error"] == nil,
                  page["status"] != .string("readback_unavailable"), page["leaseId"] == arguments["lease_id"],
                  case .string(let url)? = page["url"], case .string(let title)? = page["title"] else { return }
            target = .browserBookmark(url: url, title: title.isEmpty ? url : title,
                tabID: { if case .int(let id)? = page["tabId"] { return id }; return nil }())
        }
        guard let target, let place = Self.keepablePlace(target, session: session),
              let identity = Self.workReceiptKey(place) else { return }
        var receipts = sessions[key]?.placeActions ?? [:]
        receipts[identity] = recorded
        if receipts.count > 24 {
            let kept = Set(session.keptPlaces.compactMap(Self.workReceiptKey))
            let oldest = receipts.filter { $0.key != identity && !kept.contains($0.key) }
                .min { $0.value.observedAt == $1.value.observedAt ? $0.key < $1.key : $0.value.observedAt < $1.value.observedAt }
            if let oldest { receipts.removeValue(forKey: oldest.key) }
        }
        sessions[key]?.placeActions = receipts
    }
    static func keepablePlace(_ location: AgentWorkspaceLocation, session: Session) -> AgentWorkspaceLocation? {
        if case .page(let source, _) = location { return keepablePlace(source, session: session) }
        if case .record("agent_read", let input, _) = location,
           ["conversation_id", "message_id", "task_id"].contains(where: { input[$0] != nil }) {
            // The desktop's named-conversation serializer cannot retain these
            // exact protocol selectors. Never replace an exact reply by latest.
            return nil
        }
        let candidate = placeIdentity(location).flatMap { session.browserBookmarks[$0] } ?? location
        guard let saved = AgentWorkspaceDesktopStore.durable(candidate), placeIdentity(saved) != nil else { return nil }
        switch saved {
        case .record, .browserBookmark, .work: return saved
        case .page(let source, _): return keepablePlace(source, session: session)
        default: return nil
        }
    }

    func keepWorkPlace(_ place: AgentWorkspaceLocation, key: String) throws {
        guard var session = sessions[key], let kept = Self.keepablePlace(place, session: session) else {
            throw DesktopFailure(message: "This place has no lasting reference. Its live controls remain in the current view.")
        }
        let identity = Self.placeIdentity(kept)
        if let index = session.keptPlaces.firstIndex(where: { Self.placeIdentity($0) == identity }) {
            session.keptPlaces[index] = kept
        } else {
            guard session.keptPlaces.count < 12 else {
                throw DesktopFailure(message: "Twelve places are already kept with this work. Remove an unneeded reference before adding another; nothing was removed.")
            }
            session.keptPlaces.append(kept)
        }
        sessions[key] = session
    }

    func removeWorkPlace(_ place: AgentWorkspaceLocation, key: String) {
        let identity = Self.placeIdentity(place)
        sessions[key]?.keptPlaces.removeAll { Self.placeIdentity($0) == identity }
        sessions[key]?.workLinkNotice = nil
    }

    /// Sharing an explicitly selected source within named work carries its
    /// conversation back to that work. This records the relation, never delivery
    /// or review completion. Opening still asks the conversation's own reader.
    func attachWorkDiscussion(source: AgentWorkspaceLocation, conversation: AgentWorkspaceLocation, key: String) {
        guard var session = sessions[key], session.selectedWorkspaceID != nil || session.workNote != nil,
              let source = Self.keepablePlace(source, session: session) else { return }
        guard case .record("agent_read", let input, _) = conversation,
              case .string(let agent)? = input["agent"],
              agent.hasPrefix("bot:") || { if case .string(let label)? = input["conversation"] { return !label.isEmpty }; return false }(),
              let conversation = Self.keepablePlace(conversation, session: session) else {
            if !session.keptPlaces.contains(where: { Self.placeIdentity($0) == Self.placeIdentity(source) }), session.keptPlaces.count < 12 {
                session.keptPlaces.append(source)
            }
            session.workLinkNotice = "The discussion could not be attached to an exact saved conversation. Its outcome remains with the conversation owner; no message was repeated."
            sessions[key] = session
            return
        }
        let additions = [source, conversation].filter { candidate in
            !session.keptPlaces.contains { Self.placeIdentity($0) == Self.placeIdentity(candidate) }
        }
        guard session.keptPlaces.count + additions.count <= 12 else {
            session.workLinkNotice = "The conversation remains in Open places. This work already has twelve kept references; remove one before keeping more. The message outcome is unchanged."
            sessions[key] = session
            return
        }
        session.keptPlaces += additions
        session.workLinkNotice = nil
        sessions[key] = session
    }

    func updateWorkNote(_ text: String, key: String) throws {
        guard text.utf8.count <= 4096,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            throw DesktopFailure(message: "Keep the work note within 4 KiB of readable text. The previous note was preserved.")
        }
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[key]?.workNote = note.isEmpty ? nil : note
    }

    func workOverview(key: String) -> AgentWorkspaceProjection {
        let session = sessions[key] ?? Session()
        let name = session.saved.first(where: { $0.id == session.selectedWorkspaceID })?.name ?? "This work"
        var content: [String: JSONValue] = [
            "status": .string("ok"), "name": .string(name),
            "continuation_note": session.workNote.map(JSONValue.string) ?? .null,
            "meaning": .string("Your saved purpose, requirements and where you left off, with the places you kept beside it. The note is your account, not verified completion. References read current owner evidence when opened. A review arriving does not mean it was applied; saving a file does not satisfy the requirements by itself."),
            "unfinished_drafts": .int(Int64(session.drafts.count))
        ]
        if let issue = session.persistenceIssue { content["storage_attention"] = .string(issue) }
        if let notice = session.workLinkNotice { content["attention"] = .string(notice) }
        content["opened_sources_stay_with_work"] = .bool(session.focusedWork)
        if let receipt = session.lastWorkAction { content["last_action"] = receipt.value }
        var actions: [AgentWorkspaceButton] = [
            .init(label: session.focusedWork ? "Keep new sources manually" : "Focus on these places", action: .focusWork),
            .init(label: session.workNote == nil ? "Remember what this work needs" : "Update where I left off", action: .updateWorkNote, needsText: true),
            .init(label: "Keep this workspace as…", action: .saveWorkspace, needsText: true),
            .init(label: "Saved workspaces", action: .open(.savedWorkspaces))
        ]
        if let source = session.document, let place = Self.keepablePlace(source.location, session: session),
           !session.keptPlaces.contains(where: { Self.placeIdentity($0) == Self.placeIdentity(place) }) {
            actions.insert(.init(label: "Keep " + place.title + " with this work", action: .keepWorkPlace(place)), at: 0)
        }
        let items = session.keptPlaces.map { place in
            var recognition = Self.placeRecognition(place)
            if let receipt = Self.placeAction(place, session: session) { recognition["last_action_here"] = receipt }
            return AgentWorkspaceItem(title: place.title, content: .object(recognition), actions: [
                .init(label: "Open", action: .open(place)),
                .init(label: "Remove from this work", action: .removeWorkPlace(place))
            ])
        }
        return .init(title: name, content: .object(content), items: items, actions: actions)
    }
}
