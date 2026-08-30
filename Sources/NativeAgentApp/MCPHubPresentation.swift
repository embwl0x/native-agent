import Foundation
import NativeAgentShared
import PersistenceCore

/// Server metadata can lag the inventory already displayed below its row.
/// Only the selected server's successful read proves a current visible count.
enum MCPHubServerCountPresentation: Equatable {
    case loaded(Int)
    case reported(Int)
    case unknown

    static func resolve(
        isSelected: Bool,
        isCurrent: Bool,
        visibleCount: Int,
        reportedCount: Int?
    ) -> Self {
        if isSelected, isCurrent { return .loaded(visibleCount) }
        guard let reportedCount, reportedCount >= 0 else { return .unknown }
        return .reported(reportedCount)
    }

    func label(noun: String) -> String {
        switch self {
        case let .loaded(count):
            return "\(count) \(noun)\(count == 1 ? "" : "s")"
        case let .reported(count):
            return "\(count) \(noun)\(count == 1 ? "" : "s") reported"
        case .unknown:
            return "\(noun.capitalized) count unknown"
        }
    }

    var help: String {
        switch self {
        case .loaded:
            return "Count from this server's successfully loaded inventory."
        case .reported:
            return "Last reported by the server; its current inventory has not been verified here."
        case .unknown:
            return "This server has not reported a usable count, and its current inventory has not been loaded."
        }
    }
}
enum MCPHubResourceReadState: Equatable {
    case notLoaded
    case loading
    case current
    case unavailable(String)
}

/// Tool discovery is an independent server-scoped read. It cannot borrow the
/// resource state: one side of an MCP server can be healthy while the other
/// refuses or times out.
enum MCPHubToolReadState: Equatable {
    case notLoaded
    case loading
    case current
    case unavailable(String)
}

enum MCPHubCollectionPresentation {
    enum State: Equatable {
        case loading
        case empty
        case available
        case stale
        case unavailable
    }

    /// A panel refresh receipt is the only evidence that an empty array is a
    /// completed empty read. A failed endpoint retains earlier rows as stale,
    /// or remains unavailable when there are no prior rows to show.
    static func resolve(
        recordCount: Int,
        endpoint: String,
        refresh: AppModel.PanelRefreshStatus?
    ) -> State {
        let failed = refresh?.failedEndpoints.contains { candidate in
            candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(endpoint) == .orderedSame
        } ?? false
        if failed { return recordCount > 0 ? .stale : .unavailable }
        if recordCount > 0 { return .available }
        return refresh == nil ? .loading : .empty
    }
}

enum MCPHubInventoryPresentation {
    static func notice(
        state: MCPHubToolReadState,
        selectedServerName: String?,
        toolCount: Int
    ) -> (text: String, isFailure: Bool, showsTools: Bool) {
        switch state {
        case .notLoaded:
            return selectedServerName == nil
                ? ("Select an MCP server to inspect its tools.", false, false)
                : ("Tools have not loaded yet.", false, false)
        case .loading:
            return ("Loading tools…", false, false)
        case .unavailable(let detail):
            return ("Tools unavailable: \(detail)", true, toolCount > 0)
        case .current where toolCount == 0:
            return ("This server exposes no tools.", false, false)
        case .current:
            return ("", false, true)
        }
    }
}

enum MCPHubResourcesPresentation {
    static func notice(
        state: MCPHubResourceReadState,
        resourceCount: Int
    ) -> (text: String, isFailure: Bool)? {
        switch state {
        case .notLoaded, .loading:
            return ("Resources have not loaded yet.", false)
        case .unavailable(let detail):
            return ("Resources unavailable: \(detail)", true)
        case .current where resourceCount == 0:
            return ("No resources exposed by this server.", false)
        case .current:
            return nil
        }
    }
}

enum MCPHubRecentCallState {
    case notLoaded
    case absent
    case durable(MCPCallResult)
    case partial(MCPCallResult?, rejectedRows: Int)
    case sessionOnly(MCPCallResult)
    case latestAttemptFailed(String)
    case unavailable(String)
}

/// Reads the Activity receipt emitted by `MCPResultEvidence`, not a retained
/// view-local call result. A malformed neighbouring JSONL row is reported as
/// partial while a valid latest MCP receipt remains usable.
enum MCPHubDurableCallHistory {
    private static let maximumRows = 200

    private struct ActivityReceiptRow: Decodable {
        let id: String
        let kind: String
        let detail: String?
        let createdAt: String
        let payload: JSONValue?
    }

    static func read(root: URL) -> MCPHubRecentCallState {
        let path = root
            .appendingPathComponent("activity", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return .absent }
        let raw: String
        do {
            raw = try String(contentsOf: path, encoding: .utf8)
        } catch {
            return .unavailable(boundedDetail(error))
        }

        let lines = raw.split(whereSeparator: \.isNewline).suffix(maximumRows)
        let decoder = JSONDecoder.nativeAgent
        var rejectedRows = 0
        for line in lines.reversed() {
            guard let row = try? decoder.decode(ActivityReceiptRow.self, from: Data(line.utf8)) else {
                rejectedRows += 1
                continue
            }
            guard row.kind == "mcp_tool" else { continue }
            guard let result = callResult(from: row) else {
                rejectedRows += 1
                continue
            }
            return rejectedRows == 0 ? .durable(result) : .partial(result, rejectedRows: rejectedRows)
        }
        return rejectedRows == 0 ? .absent : .partial(nil, rejectedRows: rejectedRows)
    }

    private static func callResult(from row: ActivityReceiptRow) -> MCPCallResult? {
        guard case .object(let payload)? = row.payload,
              case .string(let serverID)? = payload["serverId"],
              case .string(let toolName)? = payload["toolName"],
              case .string(let status)? = payload["toolStatus"]
        else { return nil }
        let callID: String
        if case .string(let value)? = payload["callId"] { callID = value } else { callID = row.id }
        return MCPCallResult(
            id: callID,
            serverId: serverID,
            toolName: toolName,
            status: status,
            approvalId: nil,
            durationSeconds: double(payload["durationSeconds"]),
            createdAt: row.createdAt,
            result: payload["result"],
            resultPreview: row.detail,
            resultByteCount: integer(payload["resultByteCount"]),
            redactedByteCount: integer(payload["redactedByteCount"]),
            resultTruncated: bool(payload["resultTruncated"]),
            resultDigest: string(payload["resultDigest"]),
            receiptId: row.id,
            evidenceStatus: "recorded",
            evidenceError: nil
        )
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let result)? = value else { return nil }
        return result
    }

    private static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let result)? = value else { return nil }
        return result
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let result): return Int(result)
        case .double(let result): return Int(exactly: result)
        default: return nil
        }
    }

    private static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let result): return Double(result)
        case .double(let result): return result
        default: return nil
        }
    }

    private static func boundedDetail(_ error: any Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "The Activity receipt could not be read." : String(detail.prefix(240))
    }
}

extension NativeClient {
    func readMCPHubRecentCall() -> MCPHubRecentCallState {
        MCPHubDurableCallHistory.read(root: dataRootOverride ?? PersistenceCore.defaultDataRoot())
    }
}

extension AppModel {
    @MainActor
    func refreshMCPHubRecentCall() {
        mcpRecentCallState = client.readMCPHubRecentCall()
    }
}
