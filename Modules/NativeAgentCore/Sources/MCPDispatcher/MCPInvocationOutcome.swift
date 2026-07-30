import Foundation
import PersistenceCore

/// Transport-level interpretation of a received MCP tool response. This is
/// deliberately not a settlement model: only a domain owner can prove an
/// external effect. It exists so stdio, native, and HTTP envelopes cannot
/// disagree about whether the remote server reported an error.
public struct MCPInvocationOutcome: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case responseReceived = "response_received"
        case remoteReportedError = "remote_reported_error"
    }

    public let kind: Kind

    public var providerToolResultIsError: Bool {
        kind == .remoteReportedError
    }

    public var displayStatus: String {
        switch kind {
        case .responseReceived: "ok"
        case .remoteReportedError: "error"
        }
    }

    public static func classify(response: JSONValue) -> Self {
        Self(kind: responseReportsError(response) ? .remoteReportedError : .responseReceived)
    }

    private static func responseReportsError(_ response: JSONValue) -> Bool {
        guard case .object(let object) = response else { return false }
        if errorShape(in: object) { return true }

        // Native and HTTP adapters wrap the raw MCP tool-result under
        // `result`; stdio returns that raw result directly. Inspect one exact
        // adapter layer so both shapes have identical truth semantics without
        // interpreting arbitrary nested business payloads as protocol state.
        if case .object(let nested)? = object["result"], errorShape(in: nested) {
            return true
        }
        return false
    }

    private static func errorShape(in object: [String: JSONValue]) -> Bool {
        if case .bool(true)? = object["isError"] { return true }
        if case .bool(false)? = object["ok"] { return true }
        if case .bool(false)? = object["success"] { return true }
        if let error = object["error"], error != .null { return true }
        if case .string(let raw)? = object["status"] {
            return ["denied", "error", "failed", "failure", "rejected"]
                .contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return false
    }
}
