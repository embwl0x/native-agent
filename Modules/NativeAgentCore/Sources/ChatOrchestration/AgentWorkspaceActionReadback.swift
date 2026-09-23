import Foundation
import PersistenceCore

/// Completes an already-dispatched action with its owner's current view. This
/// never repeats an effect, changes tabs, or replaces a receipt with a claim of
/// success. Browser reads retain the exact lease; Computer reads obtain fresh
/// bounded controls, and Calendar/Reminders use their canonical bounded lists.
enum AgentWorkspaceActionReadback {
    struct Readback {
        let location: AgentWorkspaceLocation
        let result: JSONValue
    }

    private static let browserEffects: Set<String> = [
        "browser.chrome_acquire", "browser.chrome_navigate", "browser.chrome_scroll",
        "browser.chrome_click", "browser.chrome_fill", "browser.chrome_type",
        "browser.chrome_select", "browser.chrome_keypress", "browser.chrome_set_checked",
        "browser.chrome_double_click", "browser.chrome_drag",
    ]
    private static let computerEffects: Set<String> = ["go", "act", "menu_press"]
    private static let calendarReminderEffects: Set<String> = [
        "mac_calendar_create_event", "mac_calendar_modify_event", "mac_calendar_delete_event",
        "mac_reminders_create", "mac_reminders_complete",
    ]

    static func dispatchEffect(tool: String, input: [String: JSONValue], perform: AgentWorkspace.Perform) async throws -> JSONValue {
        do { return try await perform(tool, input) }
        catch is CancellationError { throw CancellationError() }
        catch {
            guard browserEffects.contains(tool) || computerEffects.contains(tool) else { throw error }
            // A thrown transport/refusal gives no portable settlement evidence.
            // Keep it visible, never repeat the effect, and recover by reading.
            return .object(["status": .string("outcome_unknown"), "error": .string(error.localizedDescription),
                "detail": .string("The action did not return a usable receipt. It was not repeated. A fresh view can show the current state; it does not prove this action completed.")])
        }
    }

    static func followUp(tool: String, input: [String: JSONValue], receipt: JSONValue,
                         title: String, perform: AgentWorkspace.Perform) async throws -> Readback? {
        let owner = object(receipt)
        let status = string(owner["status"])
        if computerEffects.contains(tool) {
            // Even a stale/refused selection returns a current, bounded set of
            // choices. Never replay an action or turn its display name into a
            // fallback target. A read is observation, not proof of settlement.
            var arguments: [String: JSONValue] = ["structured": .bool(true)]
            if tool == "menu_press", let app = string(input["app"]) { arguments["app"] = .string(app) }
            let source = AgentWorkspaceLocation.record(tool: "screen", input: arguments, title: "Computer")
            do {
                let fresh = try await perform("screen", arguments)
                return .init(location: source, result: attaching(fresh, receipt: receipt))
            } catch is CancellationError { throw CancellationError() }
            catch {
                return .init(location: source, result: unavailable(receipt: receipt,
                    detail: "The current screen could not be read: " + error.localizedDescription + ". The action was not repeated."))
            }
        }
        if calendarReminderEffects.contains(tool), status == "completed",
           owner["source"] == .string("eventkit"), !hasError(owner) {
            let placeID = tool.hasPrefix("mac_calendar_") ? "calendar" : "reminders"
            if let place = AgentWorkspaceActivity.destinations.first(where: { $0.id == placeID }), let reader = place.tool {
                let source = AgentWorkspaceLocation.record(tool: reader, input: place.input, title: place.title)
                do {
                    let current = try await perform(reader, place.input)
                    var row = object(attaching(current, receipt: receipt))
                    row["workspace_readback_scope"] = .string(placeID == "calendar"
                        ? "Upcoming events, within this reader's normal limit. The action receipt identifies the changed event; absence from this window does not mean the write failed."
                        : "Reminders due today, within this reader's normal limit. The action receipt identifies the changed reminder; completed or later reminders may not appear here.")
                    return .init(location: source, result: .object(row))
                } catch is CancellationError { throw CancellationError() }
                catch { return .init(location: source, result: unavailable(receipt: receipt, detail: "The change completed, but its current list could not be read: " + error.localizedDescription + ". Do not repeat the change.")) }
            }
        }
        if browserEffects.contains(tool), status == "outcome_unknown", owner["error"] != nil,
           let lease = string(input["lease_id"]) {
            let arguments: [String: JSONValue] = ["lease_id": .string(lease), "max_nodes": .int(80), "max_text_chars": .int(10000)]
            let source = AgentWorkspaceLocation.record(tool: "browser.chrome_snapshot", input: arguments, title: title)
            do {
                let fresh = try await perform("browser.chrome_snapshot", arguments)
                if matches(fresh, lease: lease, sequence: integer(input["expected_user_sequence"])) {
                    return .init(location: source, result: attaching(fresh, receipt: receipt))
                }
                return .init(location: source, result: unavailable(receipt: receipt, detail: "The selected page is unavailable. Reopen it to read; no browser action was repeated.", observation: fresh))
            } catch is CancellationError { throw CancellationError() }
            catch { return .init(location: source, result: unavailable(receipt: receipt, detail: "Reading the selected page failed: " + error.localizedDescription + ". No browser action was repeated.")) }
        }
        if (owner["ok"] == .bool(true) || status == "ok" || status == "completed"),
           owner["error"] == nil, owner["error_code"] == nil,
           ["write_file", "save_skill", "commit_memory", "desk_note", "desk_update_item", "desk_set_status", "desk_add_ref", "desk_add_item", "bot_create", "bot_update", "bot_pause"].contains(tool) {
            var source = AgentWorkspaceEnvironment.readback(tool: tool, input: input)
            if tool == "bot_create", let id = string(owner["id"]), UUID(uuidString: id) != nil {
                source = .record(tool: "bot_list", input: ["id": .string(id)], title: string(owner["name"]) ?? "Created helper")
            }
            if tool == "commit_memory", let id = string(owner["id"]) {
                source = .record(tool: "recall_memory", input: ["memory_id": .string(id), "max_characters": .int(2000)], title: "Recorded memory")
            }
            if tool == "desk_add_item", let handle = string(owner["handle"]) {
                source = .record(tool: "desk_read", input: ["handle": .string(handle), "structured": .bool(true)], title: "Created work")
            }
            if let source, case .record(let reader, let arguments, _) = source {
                do {
                    let current = try await perform(reader, arguments)
                    return .init(location: source, result: attaching(current, receipt: receipt))
                } catch is CancellationError { throw CancellationError() }
                catch {
                    return .init(location: source, result: unavailable(receipt: receipt,
                        detail: "The action returned, but its current result could not be read: " + error.localizedDescription + ". Reopen this source to read; do not repeat the action."))
                }
            }
        }
        guard browserEffects.contains(tool), owner["ok"] != .bool(false), owner["error"] == nil,
              owner["error_code"] == nil else { return nil }
        let actionReceipt = object(owner["receipt"] ?? .null)
        let outcome = string(owner["outcome"]) ?? string(actionReceipt["outcome"])
        let succeeded = tool == "browser.chrome_acquire" ? owner["state"] == .string("active") : outcome == "succeeded"
        guard succeeded,
              let lease = string(owner["leaseId"]) ?? string(actionReceipt["leaseId"]) ?? string(input["lease_id"]) else { return nil }
        // Even a successful-looking receipt cannot retarget the selected tab.
        if let selected = string(input["lease_id"]), selected != lease { return nil }
        let sequence = integer(owner["userSequence"]) ?? integer(actionReceipt["userSequence"]) ?? integer(input["expected_user_sequence"])
        var readInput: [String: JSONValue] = ["lease_id": .string(lease), "max_nodes": .int(80), "max_text_chars": .int(10000)]
        var location = AgentWorkspaceLocation.record(tool: "browser.chrome_snapshot", input: readInput, title: title)
        do {
            // Acquisition returns immediately after creating the tab. Let its
            // owner observe a bounded navigation quiet interval before the first
            // snapshot; this neither activates the tab nor claims load success.
            if tool == "browser.chrome_acquire", let sequence {
                let wait = try await perform("browser.chrome_wait", ["lease_id": .string(lease),
                    "expected_user_sequence": .int(sequence), "condition": .string("navigation_settled"),
                    "timeout_ms": .int(1500), "settle_ms": .int(100)])
                let waitRow = object(wait)
                if waitRow["ok"] == .bool(false) || waitRow["error"] != nil || waitRow["error_code"] != nil {
                    return .init(location: location, result: unavailable(receipt: receipt,
                        detail: "The tab opened, but its loading observation was refused. Read this page again to continue; no action was repeated.", observation: wait))
                }
            }
            var snapshot = try await perform("browser.chrome_snapshot", readInput)
            guard matches(snapshot, lease: lease, sequence: sequence) else {
                return .init(location: location, result: unavailable(receipt: receipt,
                    detail: "The action returned, but its exact page could not be read. Read this page again to continue; the action will not be repeated.", observation: snapshot))
            }
            if object(object(snapshot)["rendering"] ?? .null)["readyState"] == .string("loading") {
                try await Task.sleep(nanoseconds: 350_000_000)
                let next = try await perform("browser.chrome_snapshot", readInput)
                if matches(next, lease: lease, sequence: sequence) { snapshot = next }
                else {
                    return .init(location: location, result: unavailable(receipt: receipt,
                        detail: "The page changed while loading. Read this page again to continue; the action will not be repeated.", observation: next))
                }
            }
            let snapshotRow = object(snapshot)
            let reading = object(snapshotRow["reading"] ?? .null)
            let summary = object(snapshotRow["summary"] ?? .null)
            if reading["mainContentAvailable"] == .bool(true), reading["scope"] == .string("page"),
               case .array(let reasons)? = summary["truncationReasons"], reasons.contains(.string("node_limit")) {
                // A visible navigation/sidebar may exhaust the same 80-node
                // budget before the article. Ask the canonical owner for its
                // advertised semantic content scope, never grow the budget or
                // claim a bare HTTP title as article evidence.
                readInput["scope"] = .string("main_content")
                location = .record(tool: "browser.chrome_snapshot", input: readInput, title: title)
                let content = try await perform("browser.chrome_snapshot", readInput)
                guard matches(content, lease: lease, sequence: sequence),
                      object(object(content)["reading"] ?? .null)["scope"] == .string("main_content") else {
                    return .init(location: location, result: unavailable(receipt: receipt,
                        detail: "The page's main content could not be read from the selected tab. Read this page again to continue; no action was repeated.", observation: content))
                }
                snapshot = content
            }
            return .init(location: location, result: attaching(snapshot, receipt: receipt))
        } catch is CancellationError { throw CancellationError() }
        catch {
            return .init(location: location, result: unavailable(receipt: receipt,
                detail: "The action returned, but reading its page failed: " + error.localizedDescription
                    + ". Read this page again to continue; the action will not be repeated."))
        }
    }

    private static func matches(_ snapshot: JSONValue, lease: String, sequence: Int64?) -> Bool {
        let row = object(snapshot)
        guard row["ok"] != .bool(false), row["error"] == nil, row["error_code"] == nil,
              row["leaseId"] == .string(lease), string(row["snapshotId"]) != nil,
              integer(row["tabId"]) != nil, case .array? = row["nodes"],
              let observed = integer(row["userSequence"]) else { return false }
        return sequence == nil || observed == sequence
    }

    private static func attaching(_ result: JSONValue, receipt: JSONValue) -> JSONValue {
        var row = object(result)
        if case .string(let text) = result { row["content"] = .string(text) }
        row["action_receipt"] = AgentWorkspaceEnvironment.retained(receipt)
        return .object(row)
    }

    private static func unavailable(receipt: JSONValue, detail: String, observation: JSONValue? = nil) -> JSONValue {
        var row: [String: JSONValue] = ["status": .string("readback_unavailable"), "detail": .string(detail),
            "action_receipt": AgentWorkspaceEnvironment.retained(receipt)]
        if let observation { row["readback"] = AgentWorkspaceEnvironment.retained(observation) }
        return .object(row)
    }

    private static func object(_ value: JSONValue) -> [String: JSONValue] { if case .object(let row) = value { return row }; return [:] }
    private static func hasError(_ row: [String: JSONValue]) -> Bool {
        ["error", "error_code"].contains { row[$0] != nil && row[$0] != .null }
    }
    private static func string(_ value: JSONValue?) -> String? { guard case .string(let text)? = value, !text.isEmpty, text.count <= 8192 else { return nil }; return text }
    private static func integer(_ value: JSONValue?) -> Int64? { guard case .int(let value)? = value, value >= 0 else { return nil }; return value }
}
