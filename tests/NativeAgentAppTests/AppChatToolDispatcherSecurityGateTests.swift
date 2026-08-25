import ChatOrchestration
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
import TrustCenter
@testable import NativeAgentApp

// EVAL — ledger fence app.runtimes, row `tools.securityGate`
// (AppChatToolDispatcher.swift:255 evaluateTool + :261 securityGateResponse +
// :1083 securityOrigin).
//
// The ledger's finding: every existing dispatcher test constructs the shim with
// `enforceAutonomySecurity: false`, and `grep -rn 'enforceAutonomySecurity: true'
// tests/` returned NOTHING. So the deny path, the recorded envelope, and the
// remote-origin derivation had NO coverage in any tier — a regression that
// allowed everything would have been invisible.
//
// These tests run the gate ENFORCED on an injected temp root (never the live
// security store) and assert the three envelope properties that make the gate
// observable:
//   1. a blocked evaluation returns the gate envelope AND the inner dispatcher
//      is never reached (no side effect escapes ahead of the decision);
//   2. the same call with the gate satisfied DOES reach inner — without this
//      arm the block test would pass on a dispatcher that blocks everything;
//   3. every evaluation writes an audit receipt carrying the derived origin,
//      including `isRemote` for a remote surface.
//
// NOTE: fences.md marks trust work INVENTORY ONLY. Nothing here changes gate
// behavior; these are read-only observations of the current contract.
@Suite("App chat tool dispatcher security gate", .serialized)
struct AppChatToolDispatcherSecurityGateTests {
    private func makeRoot(killSwitch: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("security-gate-\(UUID().uuidString)", isDirectory: true)
        let trust = root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: trust, withIntermediateDirectories: true)
        let policy = "{\"securityPolicy\":{\"killSwitchEnabled\":\(killSwitch)}}"
        try Data(policy.utf8).write(to: trust.appendingPathComponent("policy.json"))
        return root
    }

    private func dispatcher(
        root: URL,
        inner: RecordingSecurityInnerDispatcher
    ) -> AppChatToolDispatcher {
        AppChatToolDispatcher(
            inner: inner,
            securityCenter: SwiftNativeSecurityCenter(dataRoot: root),
            enforceAutonomySecurity: true,
            organismPostureProvider: { nil }
        )
    }

    private func auditRows(root: URL) throws -> [[String: Any]] {
        let path = root
            .appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
    }

    @Test("an enforced block returns the gate envelope and never reaches the inner dispatcher")
    func blockedToolNeverReachesInner() async throws {
        let root = try makeRoot(killSwitch: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = RecordingSecurityInnerDispatcher()

        let result = try await dispatcher(root: root, inner: inner).dispatch(
            tool: "read_file",
            input: ["path": .string(root.appendingPathComponent("notes.txt").path)],
            surface: "chat"
        )

        guard case .object(let envelope) = result else {
            Issue.record("the gate must answer with an envelope object")
            return
        }
        #expect(envelope["allowed"] == .bool(false))
        #expect(envelope["status"] == .string("blocked"))
        #expect(envelope["tool"] == .string("read_file"))
        #expect(envelope["runtime"] == .string("swift-native"))
        if case .array(let reasons)? = envelope["reasons"] {
            #expect(reasons.contains(.string("security kill switch is active")))
        } else {
            Issue.record("a blocked envelope must carry its reasons")
        }
        // THE tooth: the decision precedes the effect.
        #expect(
            await inner.dispatchedTools.isEmpty,
            "a blocked tool must never reach the inner dispatcher"
        )
    }

    @Test("with the gate satisfied the same enforced call does reach inner")
    func allowedToolReachesInnerUnderEnforcement() async throws {
        let root = try makeRoot(killSwitch: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = RecordingSecurityInnerDispatcher()

        let result = try await dispatcher(root: root, inner: inner).dispatch(
            tool: "read_file",
            input: ["path": .string(root.appendingPathComponent("notes.txt").path)],
            surface: "chat"
        )

        // Without this arm the block test above would still pass on a gate that
        // denied EVERYTHING — the exact silent-authorization regression the
        // ledger names, inverted.
        #expect(
            await inner.dispatchedTools == ["read_file"],
            "an enforced-but-permitted local read must still execute"
        )
        if case .object(let object) = result {
            #expect(object["delegated"] == .bool(true))
        } else {
            Issue.record("inner's result must be returned verbatim")
        }
    }

    @Test("every evaluation records an audit receipt carrying the derived origin")
    func evaluationRecordsOriginInTheAuditReceipt() async throws {
        let root = try makeRoot(killSwitch: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = RecordingSecurityInnerDispatcher()
        let shim = dispatcher(root: root, inner: inner)

        _ = try? await shim.dispatch(
            tool: "read_file",
            input: ["path": .string(root.appendingPathComponent("a.txt").path)],
            surface: "chat"
        )
        _ = try? await shim.dispatch(
            tool: "read_file",
            input: ["path": .string(root.appendingPathComponent("b.txt").path)],
            surface: "telegram"
        )

        let rows = try auditRows(root: root)
        #expect(rows.count == 2, "a dispatch with no receipt is an unauditable authorization")

        let origins = rows.compactMap { $0["origin"] as? [String: Any] }
        let local = origins.first { ($0["surface"] as? String) == "chat" }
        let remote = origins.first { ($0["surface"] as? String) == "telegram" }
        #expect(local?["is_remote"] as? Bool == false)
        #expect(
            remote?["is_remote"] as? Bool == true,
            "a remote surface must derive isRemote — the remote-origin gates are dead otherwise"
        )
        #expect(origins.allSatisfy { ($0["source"] as? String) == "app_chat_tool_dispatcher" })
    }
}

private actor RecordingSecurityInnerDispatcher: ToolDispatchClient {
    private(set) var dispatchedTools: [String] = []

    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        dispatchedTools.append(tool)
        return .object([
            "tool": .string(tool),
            "surface": .string(surface),
            "delegated": .bool(true),
        ])
    }

    func listAvailableTools() async throws -> [String] { ["read_file"] }

    func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}
