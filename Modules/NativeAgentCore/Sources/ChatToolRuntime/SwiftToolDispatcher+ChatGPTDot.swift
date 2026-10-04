import AgentConversations
import Foundation
import MacControl
import PersistenceCore

extension SwiftToolDispatcher {
    public func chatGPTDotReadiness(force: Bool = false) async -> JSONValue {
        let current = ChatGPTDotIPCTransport.readiness
        if !force, case .object(let fields) = current, fields["status"] != .string("not_checked") { return current }
        let stamp = ChatGPTDotIPCTransport.stamp
        let receipt = await dotHelper(["action": .string("handshake")])
        ChatGPTDotIPCTransport.retainHandshake(receipt, stamp: stamp)
        return receipt
    }

    func chatGPTDotMessage(_ args: [String: JSONValue], peer: AgentPeerContact, sending: Bool) async throws -> JSONValue {
        guard args["task_id"] == nil, args["message_id"] == nil else {
            throw AgentCommunicationError.invalid("Dot has one conversation; read or send to the contact.")
        }
        var input: [String: JSONValue] = ["action": .string(sending ? "send" : "read")]
        input["conversation_id"] = args["conversation_id"]
        if sending {
            guard case .string(let text)? = args["text"],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 64000 else {
                throw AgentCommunicationError.invalid("Dot messages require text of at most 64000 characters.")
            }
            // Dot answers in his own chat; the app pulls his reply into Agent's
            // session as an ordinary message that wakes her. No command, no approval.
            input["text"] = .string(text + Self.dotReplyFooter)
            // Busy means nothing was sent: wait for ChatGPT to free up (up to 2 minutes).
            var result = await dotHelper(input)
            for _ in 0..<24 {
                guard case .object(let fields) = result, fields["status"] == .string("busy") else { break }
                try await Task.sleep(nanoseconds: 5_000_000_000)
                result = await dotHelper(input)
            }
            if case .object(let fields) = result, fields["sent"] != .bool(false) {
                try? await SwiftNativePersistenceCore().writeJSON(.string(ISO8601DateFormatter().string(from: Date())),
                    to: ChatGPTDotIPCTransport.recentSendFile(dataRoot))
            }
            if case .object(let fields) = result, fields["status"] == .string("sent") || fields["sent"] == .bool(true) {
                do { _ = try await ChatGPTDotIPCTransport.conversation(dataRoot, peer, [result], text) }
                catch {
                    return .object(["status": .string("sent"), "sent": .bool(true),
                                    "detail": .string("ChatGPT accepted the message, but its local transcript could not be saved. Nothing was resent.")])
                }
            }
            return result
        }
        // A read right after Agent's send waits for Dot's answer: keep pulling
        // while her message is still the last one, until he replies or time runs out.
        let deadline = Date().addingTimeInterval(await dotReadWait(args))
        while true {
            let result = await dotHelper(input)
            guard case .object(let fields) = result, fields["status"] == .string("ok"),
                  case .array(let messages)? = fields["messages"] else { return result }
            let conversation = try await ChatGPTDotIPCTransport.conversation(dataRoot, peer, messages, nil)
            guard Self.dotAwaitsReply(conversation), Date() < deadline else { return conversation }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Explicit wait_seconds wins (max 60); otherwise a read within two minutes of a send waits up to 20 s.
    private func dotReadWait(_ args: [String: JSONValue]) async -> TimeInterval {
        switch args["wait_seconds"] {
        case .int(let seconds)?: return TimeInterval(min(max(seconds, 0), 60))
        case .double(let seconds)?: return min(max(seconds, 0), 60)
        default: break
        }
        guard case .string(let stamp)? = try? await SwiftNativePersistenceCore().readJSON(
                  ChatGPTDotIPCTransport.recentSendFile(dataRoot), ifMissing: .null),
              let sent = ISO8601DateFormatter().date(from: stamp) else { return 0 }
        return Date().timeIntervalSince(sent) < 120 ? 20 : 0
    }

    static let dotReplyFooter = "\n\n— From Agent via NativeAgent. Reply right here in this chat; your reply reaches her automatically. To send her something later, start the message with \"Agent,\"."

    static func dotAwaitsReply(_ conversation: JSONValue) -> Bool {
        guard case .object(let fields) = conversation, case .array(let rows)? = fields["conversation"],
              case .object(let last)? = rows.last else { return false }
        return last["from"] == .string("Agent")
    }

    private func dotHelper(_ input: [String: JSONValue]) async -> JSONValue {
        let environment = AgentBridgeRuntime.processEnvironment()
        guard let helper = AgentBridgeRuntime.helperURL(named: "chatgpt_dot_ipc.js", dataRoot: dataRoot),
              let node = AgentBridgeRuntime.executableURL(named: "node", environment: environment),
              let bytes = try? JSONEncoder().encode(JSONValue.object(input)) else {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                "detail": .string("Dot messaging helper or Node.js is unavailable.")])
        }
        let failure: JSONValue = input["action"] == .string("send")
            ? .object(["status": .string("outcome_unknown"), "sent": .null,
                       "detail": .string("Dot acknowledgement is unavailable; nothing was resent.")])
            : .object(["status": .string("unavailable"),
                       "detail": .string("Dot's current conversation cannot be followed.")])
        do {
            let result = try await SystemProcessAdapter().run(executable: node.path, arguments: [helper.path],
                currentDirectory: dataRoot, environment: environment, standardInput: bytes,
                timeoutSeconds: 35, outputByteLimit: nil)
            guard result.exitCode == 0, let output = result.stdout.data(using: .utf8),
                  let receipt = try? JSONDecoder().decode(JSONValue.self, from: output) else {
                return failure
            }
            return receipt
        } catch {
            return failure
        }
    }
}
