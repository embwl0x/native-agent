import Foundation
import NativeAgentCore
import PersistenceCore

/// An explicit find-and-load request uses the final catalog ranking. Discovery
/// remains read-only by default; loading never executes the selected capability.
public enum ToolCatalogSelection {
    public static func selectedName(in result: JSONValue) -> String? {
        guard case .object(let envelope) = result,
              envelope["status"] == .string("ok"),
              case .array(let matches)? = envelope["matches"],
              let first = matches.first, case .object(let winner) = first,
              case .string(let name)? = winner["name"],
              !name.hasPrefix("mcp__"),
              case .int(let score)? = winner["match_score"], score > 0 else { return nil }
        // A tied shortlist needs the agent's judgment; don't load competing
        // families or use alphabetical order as a capability decision.
        if matches.dropFirst().contains(where: { value in
            guard case .object(let row) = value else { return false }
            return row["match_score"] == .int(score)
        }) { return nil }
        // A one-row requested limit can conceal a tie; callers obtain at least
        // two rows before consulting this selector.
        return name
    }

    public static func searchInput(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var search = input
        search.removeValue(forKey: "load")
        let limit: Int64
        switch search["limit"] {
        case .int(let value): limit = value
        case .double(let value): limit = Int64(exactly: value) ?? 10
        default: limit = 10
        }
        search["limit"] = .int(max(2, min(25, limit)))
        return search
    }

    public static func finish(_ result: JSONValue, selected: String?, loading: JSONValue?) -> JSONValue {
        guard case .object(var envelope) = result else { return result }
        envelope["readiness"] = .string("Catalog visibility and loaded schemas are not a live connection or permission check. Execution keeps the existing gates.")
        guard let selected, let loading else {
            envelope["selection_status"] = .string("needs_selection")
            envelope["selection_note"] = .string("Nothing was loaded. Refine the query or choose an exact tool from the matches; tied matches and external MCP tools require explicit selection.")
            return .object(envelope)
        }
        envelope["selected_tool"] = .string(selected)
        envelope["loading"] = loading
        var loaded = false
        if case .object(let receipt) = loading {
            // Keep the existing loader contract at the usual envelope level,
            // including schemas for providers whose tool list is turn-pinned.
            for key in ["loaded", "loaded_now", "already_active", "schemas_added", "next_turn_note"] {
                envelope[key] = receipt[key]
            }
            for key in ["loaded", "already_active"] {
                if case .array(let values)? = receipt[key], values.contains(.string(selected)) { loaded = true }
            }
        }
        envelope["selection_status"] = .string(loaded ? "loaded" : "not_loaded")
        if loaded { envelope["selection_note"] = .string("Ready to call the selected tool. Its schema is in schemas_added when newly loaded; no separate tool_load is needed.") }
        if loaded {
            envelope.removeValue(forKey: "load_next")
            if case .array(let matches)? = envelope["matches"] {
                envelope["matches"] = .array(matches.map { value in
                    guard case .object(var row) = value, row["name"] == .string(selected) else { return value }
                    row["load_state"] = .string("loaded")
                    return .object(row)
                })
            }
        }
        envelope["note"] = .string("The unique best native match was offered to the existing session loader. Check loading for the actual outcome and schema; no task action was executed.")
        return .object(envelope)
    }
}
