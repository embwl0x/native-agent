import AgentConversations
import Foundation
import MacControl
import PersistenceCore

extension SwiftToolDispatcher {
    /// Dot's live state; a listener that is not running starts (and says why if it cannot follow him).
    public func chatGPTDotReadiness() async -> JSONValue {
        ChatGPTDotIPCTransport.reconnect()
        return ChatGPTDotIPCTransport.readiness
    }

    func chatGPTDotMessage(_ args: [String: JSONValue], peer: AgentPeerContact, sending: Bool) async throws -> JSONValue {
        guard args["task_id"] == nil, args["message_id"] == nil else {
            throw AgentCommunicationError.invalid("Dot has one conversation; read or send to the contact.")
        }
        if sending {
            guard case .string(let text)? = args["text"],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 64000 else {
                throw AgentCommunicationError.invalid("Dot messages require text of at most 64000 characters.")
            }
            var input: [String: JSONValue] = ["action": .string("send")]
            input["conversation_id"] = args["conversation_id"]
            // Dot answers in his own chat; the listener brings his reply into
            // Agent's session as an ordinary message that wakes her. No command, no approval.
            input["text"] = .string(text + Self.dotReplyFooter)
            // Busy means nothing was sent: wait for ChatGPT to free up (up to 2 minutes).
            var result = await dotHelper(input)
            for _ in 0..<24 {
                guard case .object(let fields) = result, fields["status"] == .string("busy") else { break }
                try await Task.sleep(nanoseconds: 5_000_000_000)
                result = await dotHelper(input)
            }
            if case .object(let fields) = result, fields["status"] == .string("sent") || fields["sent"] == .bool(true) {
                AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peer.id, outbound: true)
                do { _ = try await ChatGPTDotIPCTransport.conversation(dataRoot, peer, [result], text) }
                catch {
                    return .object(["status": .string("sent"), "sent": .bool(true),
                                    "detail": .string("ChatGPT accepted the message, but its local transcript could not be saved. Nothing was resent.")])
                }
            } else if case .object(let fields) = result, fields["status"] != .string("busy") {
                AgentPeerStore(dataRoot: dataRoot).recordUnavailable(peerID: peer.id)
            }
            return result
        }
        // His room reaches her session through the listener as it changes;
        // a read is her Dot session itself, and says so when he can't be followed.
        var window = try [
            "limit": Self.dotPage(args, "limit", default: 10, range: 1...100),
            "offset": Self.dotPage(args, "offset", default: 0, range: 0...Int.max),
            "max_chars": Self.dotPage(args, "max_chars", default: 8000, range: 1...16000),
            "text_offset": Self.dotPage(args, "text_offset", default: 0, range: 0...Int.max),
        ].mapValues { JSONValue.int(Int64($0)) }
        for key in ["conversation_id", "source_version"] {
            if let value = args[key], value != .null {
                guard case .string = value else { throw AgentCommunicationError.invalid("Dot's \(key) must be a string. Omit it for a fresh read.") }
                window[key] = value
            }
        }
        let conversation = try await ChatGPTDotIPCTransport.conversation(dataRoot, peer, [], nil, window: window)
        guard !ChatGPTDotIPCTransport.available, case .object(var fields) = conversation else { return conversation }
        fields["state_detail"] = .string(ChatGPTDotIPCTransport.detail)
        return .object(fields)
    }

    static let dotReplyFooter = "\n\n— From Agent via NativeAgent. Reply right here in this chat; your reply reaches her automatically. To send her something later, start the message with \"Agent,\"."

    private static func dotPage(_ args: [String: JSONValue], _ key: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
        guard let input = args[key], input != .null else { return value }
        guard case .int(let number) = input, let integer = Int(exactly: number), range.contains(integer) else {
            throw AgentCommunicationError.invalid("Dot's \(key) must be an integer in \(range). Read Dot again with a valid window.")
        }
        return integer
    }

    private func dotHelper(_ input: [String: JSONValue]) async -> JSONValue {
        let environment = AgentBridgeRuntime.processEnvironment()
        guard let helper = AgentBridgeRuntime.helperURL(named: "chatgpt_dot_ipc.js", dataRoot: dataRoot),
              let node = AgentBridgeRuntime.executableURL(named: "node", environment: environment),
              let bytes = try? JSONEncoder().encode(JSONValue.object(input)) else {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                "detail": .string("Dot messaging helper or Node.js is unavailable.")])
        }
        let failure: JSONValue = .object(["status": .string("outcome_unknown"), "sent": .null,
                                          "detail": .string("Dot acknowledgement is unavailable; nothing was resent.")])
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
