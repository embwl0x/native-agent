import Darwin
import Foundation
import Testing
@testable import NativeAgentApp

@Suite struct NativeAgentPeerBridgeTests {
    @Test func genericConnectionOwnsFreshPersistentIdentityAndContinuesExactly() throws {
        let first = try #require(ClaudeBridge.genericAgentSessionID(requested: nil))
        let second = try #require(ClaudeBridge.genericAgentSessionID(requested: nil))
        #expect(UUID(uuidString: first) != nil)
        #expect(UUID(uuidString: second) != nil)
        #expect(first != second)
        #expect(ClaudeBridge.genericAgentSessionID(requested: first) == first)
        #expect(ClaudeBridge.genericAgentSessionID(requested: "known-session") == "known-session")
        for invalid in ["", " ", " known-session ", "../private", "a/b", "a\\b", "a\n", String(repeating: "x", count: 129)] {
            #expect(ClaudeBridge.genericAgentSessionID(requested: invalid) == nil)
            #expect(!ClaudeBridge.validGenericAgentMessage(["text": "Hello", "sessionId": invalid]))
        }
        // Legacy routes retain their separate selected-session contract.
        #expect(ClaudeBridge.bridgeMessageSessionID(requested: nil, active: "user-chat") == "user-chat")
        #expect((ClaudeBridge.agentPeerCard()["message"] as? [String: Any])?["omitted_session"] as? String == "new_conversation")
    }
    @Test func genericMessageAllowsOnlyBoundedTextAndCorrelationIdentity() {
        let valid: [String: Any] = ["text": "Hello peer", "sessionId": "session", "request_id": UUID().uuidString]
        #expect(ClaudeBridge.validGenericAgentMessage(valid))
        for (key, value) in [("sender", "user"), ("ackMode", "enqueue_only"), ("request_id", "not-uuid"), ("sessionId", "")] {
            var invalid = valid
            invalid[key] = value
            #expect(!ClaudeBridge.validGenericAgentMessage(invalid))
        }
        #expect(!ClaudeBridge.validGenericAgentMessage(["text": String(repeating: "x", count: 64001)]))
    }
    @Test func olderReceiptShapesCannotPoisonAnExactModernReceipt() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var bytes = Data("{\"at\":\"legacy\",\"response\":\"old reply\"}\n{\"requestId\":\"other\",\"detail\":\"unrelated variant\"}\n".utf8)
        bytes.append(try row())
        try bytes.write(to: file)
        let result = read(file)
        #expect(result["status"] as? String == "ok")
        #expect(result["evidence"] as? String == "exact_receipt")
        #expect(result["reply"] as? String == "Hello 🐚 friend")
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-replies-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("replies.jsonl")
    }
    private func row(_ request: String = "request-a", session: String = "session-a", reply: String = "Hello 🐚 friend") throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: ["requestId": request, "sessionId": session,
            "reply": reply, "runId": "run-a", "status": "ok"])
        bytes.append(0x0A)
        return bytes
    }
    private func read(_ file: URL, request: String = "request-a", session: String = "session-a", offset: Int = 0, maxChars: Int = 8000) -> [String: Any] {
        ClaudeBridge.agentReplyReceipt(requestID: request, sessionID: session, offset: offset, maxChars: maxChars, logURL: file)
    }

    @Test func cardAdvertisesOnlyGenericAuthenticatedProtocolAndAgentLane() throws {
        let card = ClaudeBridge.agentPeerCard()
        #expect(card["protocol"] as? String == "nativeagent-bridge")
        #expect((card["authentication"] as? [String: Any])?["required"] as? Bool == true)
        #expect((card["message"] as? [String: Any])?["path"] as? String == "/agent/message")
        #expect((card["reply"] as? [String: Any])?["path"] as? String == "/agent/reply")
        #expect(ClaudeBridge.laneAuthorship(forSender: "agent") == .agent)
        #expect(ClaudeBridge.bridgeSurfaceName(forSender: "agent") == "agent-bridge")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: card), as: UTF8.self)
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("Bearer "))
    }

    @Test func exactIdentitySessionIsolationAndUnicodePaging() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var bytes = try row("other", session: "elsewhere", reply: "request-a mentioned in unrelated text")
        bytes.append(try row())
        try bytes.write(to: file)
        let first = read(file, maxChars: 7)
        #expect(first["status"] as? String == "ok")
        #expect(first["original_status"] as? String == "ok")
        #expect(first["run_id"] as? String == "run-a")
        #expect(first["reply"] as? String == "Hello 🐚")
        #expect(first["next_offset"] as? Int == 7)
        #expect(first["has_more"] as? Bool == true)
        let last = read(file, offset: 7)
        #expect(last["reply"] as? String == " friend")
        #expect(last["has_more"] as? Bool == false)
        let wrongSession = read(file, session: "elsewhere")
        #expect(wrongSession["status"] as? String == "not_found")
        #expect(wrongSession["reply"] == nil)
        #expect(wrongSession["run_id"] == nil)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func absentIsUnknownOutcomeNotFailedWork() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for create in [false, true] {
            if create { try row("different").write(to: file) }
            let result = read(file)
            #expect(result["status"] as? String == "not_found")
            #expect(result["original_outcome"] as? String == "unknown")
            #expect(result["reply"] == nil)
            #expect((result["coverage"] as? [String: Any])?["complete"] as? Bool == true)
        }
    }

    @Test func duplicateIdentityIsAmbiguousEvenAcrossSessions() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for session in ["session-a", "private-session"] {
            var data = try row()
            data.append(try row(session: session, reply: "private"))
            try data.write(to: file)
            let result = read(file)
            #expect(result["status"] as? String == "unavailable")
            #expect(result["evidence"] as? String == "ambiguous_receipt")
            #expect(result["reply"] == nil)
        }
    }

    @Test func malformedAndInvalidEncodingCannotEstablishUniqueness() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for (suffix, evidence) in [(Data("broken\n".utf8), "malformed_receipts"), (Data([0xFF, 0x0A]), "invalid_encoding"), (Data("[]\n".utf8), "malformed_receipts"), (Data("{\"requestId\":\"request-a\"}\n".utf8), "malformed_receipts")] {
            var bytes = try row()
            bytes.append(suffix)
            try bytes.write(to: file)
            let result = read(file)
            #expect(result["status"] as? String == "unavailable")
            #expect(result["evidence"] as? String == evidence)
            #expect(result["reply"] == nil)
            #expect((result["coverage"] as? [String: Any])?["complete"] as? Bool == false)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func limitsAndNonregularInputsFailWithoutBlocking() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(mkfifo(file.path, 0o600) == 0)
        #expect(read(file)["evidence"] as? String == "unreadable_receipts")
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 0x20, count: 1_048_577).write(to: file)
        #expect(read(file)["evidence"] as? String == "row_limit")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 16 * 1_048_576 + 1)
        try handle.close()
        #expect(read(file)["evidence"] as? String == "scan_limit")
        #expect(read(file, offset: -1)["status"] as? String == "invalid_request")
        #expect(read(file, maxChars: 16001)["status"] as? String == "invalid_request")
        #expect(read(file, request: "")["status"] as? String == "invalid_request")
    }

    @Test func oldRowsWithoutRequestIdentityDoNotMatchTextOrExposePaths() throws {
        let file = try fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("{\"status\":\"ok\",\"reply\":\"request-a /Users/private/file\"}\n".utf8).write(to: file)
        let result = read(file)
        #expect(result["status"] as? String == "not_found")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        #expect(!text.contains("/Users/private"))
        #expect(!text.contains(file.path))
    }
}
