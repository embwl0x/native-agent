import Foundation
import PersistenceCore
import ChatToolParsing
// Blueprint: | `AgentWorkspaceActionReadback.swift` | `AgentWorkspaceActionReadback`: surviving item effects and exact-owner readback without replay |

enum AgentWorkspaceActionReadback {
    struct Readback {
        let location: AgentWorkspaceLocation
        let result: JSONValue
    }

    private static let browserEffects: Set<String> = [
        "browser.chrome_navigate", "browser.chrome_scroll",
        "browser.chrome_click", "browser.chrome_fill",
    ]
    private static let computerEffects: Set<String> = ["go", "act", "menu_press"]
    static func dispatchEffect(tool: String, input: [String: JSONValue], perform: AgentWorkspace.Perform) async throws -> JSONValue {
        do { return try await perform(tool, input) }
        catch is CancellationError { throw CancellationError() }
        catch {
            guard browserEffects.contains(tool) || computerEffects.contains(tool) else { throw error }
            return .object(["status": .string("outcome_unknown"), "error": .string(error.localizedDescription),
                "detail": .string("""
                    The action did not return a usable receipt. It was not repeated. A fresh view can show the current state; it does not prove this action \
                    completed.
                    """)])
        }
    }

    static func followUp(tool: String, input: [String: JSONValue], receipt: JSONValue,
                         title: String, perform: AgentWorkspace.Perform) async throws -> Readback? {
        let reply = ToolResult(receipt)
        let owner = object(receipt)
        let status = string(owner["status"])
        var source: AgentWorkspaceLocation?
        var scope: String?
        var failure = "The action returned, but its current result could not be read: "
        var caution = ". Reopen this source to read; do not repeat the action."
        if computerEffects.contains(tool) {
            var arguments: [String: JSONValue] = ["structured": .bool(true)]
            let detail = object(owner["detail"] ?? .null)
            let output = object(owner["output"] ?? .null)
            func recipient(_ fields: [String: JSONValue]) -> String? {
                let app = object(fields["app"] ?? .null)
                return string(fields["bundle_identifier"]) ?? string(app["bundle_id"])
                    ?? string(fields["app"]) ?? string(app["name"]) ?? string(fields["matched_name"])
            }
            let app = recipient(detail) ?? recipient(output) ?? recipient(owner) ?? string(input["app"])
            if let app { arguments["app"] = .string(app) }
            let computer = AgentWorkspaceLocation.record(tool: "screen", input: arguments, title: "Computer")
            guard app != nil else {
                return .init(location: computer, result: unavailable(receipt: receipt,
                    detail: """
                        The action did not identify its receiving app. Read the intended app explicitly; foreground state would not establish this action's \
                        destination. The action was not repeated.
                        """))
            }
            source = computer
            failure = "The current screen could not be read: "
            caution = ". The action was not repeated."
        } else if tool == "mac_reminders_complete", status == "completed",
           owner["source"] == .string("eventkit"), reply.outcome == .succeeded {
            caution = ". Do not repeat the change."
            if let id = string(owner["reminderId"]) {
                source = .record(tool: "mac_reminders_read", input: ["id": .string(id)], title: "Reminder")
                failure = "The change completed, but the exact reminder could not be read: "
            } else {
                let placeID = "reminders"
                if let place = AgentWorkspaceActivity.destinations.first(where: { $0.id == placeID }), let reader = place.tool {
                    source = .record(tool: reader, input: place.input, title: place.title)
                    failure = "The change completed, but its current list could not be read: "
                    scope = "Incomplete reminders across all dates, within this reader's normal limit. Completed reminders may not appear here."
                }
            }
        } else if reply.outcome == .succeeded,
           ["write_file", "desk_note", "desk_set_status", "bot_pause"].contains(tool) {
            source = AgentWorkspaceEnvironment.readback(tool: tool, input: input)
        }
        if let source, case .record(let reader, let arguments, _) = source {
            do {
                let current = try await perform(reader, arguments)
                let location = reader == "desk_read"
                    ? AgentWorkspaceLocation.record(tool: reader, input: arguments,
                        title: AgentWorkspaceWork.desk(input: arguments, result: current).title)
                    : source
                var row = object(attaching(current, receipt: receipt))
                if let scope { row["workspace_readback_scope"] = .string(scope) }
                return .init(location: location, result: .object(row))
            } catch is CancellationError { throw CancellationError() }
            catch {
                return .init(location: source, result: unavailable(receipt: receipt,
                    detail: failure + error.localizedDescription + caution))
            }
        }
        if browserEffects.contains(tool), status == "outcome_unknown", owner["error"] != nil,
           let tab = integer(input["tab_id"]) {
            let arguments: [String: JSONValue] = ["tab_id": .int(tab)]
            let source = AgentWorkspaceLocation.record(tool: "browser.chrome_snapshot", input: arguments, title: title)
            do {
                let fresh = try await perform("browser.chrome_snapshot", arguments)
                if matches(fresh, tab: tab, sequence: integer(input["expected_user_sequence"])) {
                    return .init(location: source, result: attaching(fresh, receipt: receipt))
                }
                return .init(location: source, result: unavailable(receipt: receipt,
                    detail: "The selected page is unavailable. Reopen it to read; no browser action was repeated.", observation: fresh))
            } catch is CancellationError { throw CancellationError() }
            catch { return .init(location: source, result: unavailable(receipt: receipt, detail: "Reading the selected page failed: " + error
                .localizedDescription + ". No browser action was repeated.")) }
        }
        guard browserEffects.contains(tool), owner["ok"] != .bool(false), owner["error"] == nil,
              owner["error_code"] == nil else { return nil }
        let actionReceipt = object(owner["receipt"] ?? .null)
        let outcome = string(owner["outcome"]) ?? string(actionReceipt["outcome"])
        let succeeded = outcome == "succeeded"
        guard succeeded,
              let tab = integer(owner["tabId"]) ?? integer(actionReceipt["tabId"]) ?? integer(input["tab_id"]) else { return nil }
        if tool != "browser.chrome_navigate", let selected = integer(input["tab_id"]), selected != tab { return nil }
        let sequence = integer(owner["userSequence"]) ?? integer(actionReceipt["userSequence"]) ?? integer(input["expected_user_sequence"])
        let readInput: [String: JSONValue] = ["tab_id": .int(tab)]
        var requestInput = readInput
        if tool == "browser.chrome_navigate" {
            requestInput["__chrome_document_id"] = owner["documentId"]
            requestInput["__chrome_page_url"] = owner["url"]
        }
        let location = AgentWorkspaceLocation.record(tool: "browser.chrome_snapshot", input: readInput, title: title)
        do {
            let snapshot = try await perform("browser.chrome_snapshot", requestInput)
            guard matches(snapshot, tab: tab, sequence: sequence) else {
                return .init(location: location, result: unavailable(receipt: receipt,
                    detail: "The action returned, but its exact page could not be read. Read this page again to continue; the action will not be repeated.",
                        observation: snapshot))
            }
            return .init(location: location, result: attaching(snapshot, receipt: receipt))
        } catch is CancellationError { throw CancellationError() }
        catch {
            return .init(location: location, result: unavailable(receipt: receipt,
                detail: "The action returned, but reading its page failed: " + error.localizedDescription
                    + ". Read this page again to continue; the action will not be repeated."))
        }
    }

    private static func matches(_ snapshot: JSONValue, tab: Int64, sequence: Int64?) -> Bool {
        let reply = ToolResult(snapshot)
        let row = object(snapshot)
        guard reply.hasReadEvidence(),
              row["tabId"] == .int(tab), string(row["snapshotId"]) != nil,
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
    private static func string(_ value: JSONValue?) -> String? { guard case .string(let text)? = value, !text.isEmpty, text.count <= 8192 else { return nil };
        return text }
    private static func integer(_ value: JSONValue?) -> Int64? { guard case .int(let value)? = value, value >= 0 else { return nil }; return value }
}
