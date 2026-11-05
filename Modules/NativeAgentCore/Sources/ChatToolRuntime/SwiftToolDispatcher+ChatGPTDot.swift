import AgentConversations
import ChatToolParsing
import Foundation
import NativeAgentCore
import MacControl
import PersistenceCore
import PersonaEngine
// Blueprint: | `SwiftToolDispatcher+ChatGPTDot.swift` | `SwiftToolDispatcher`: `chatGPTDotReadiness`, `chatGPTDotMessage` |

extension SwiftToolDispatcher {
    /// Starts the listener so readiness reflects whether replies can reach this session.
    public func chatGPTDotReadiness() async -> JSONValue {
        ChatGPTDotIPCTransport.reconnect()
        return ChatGPTDotIPCTransport.readiness
    }

    func chatGPTDotMessage(turn: Turn, _ args: [String: JSONValue], peer: AgentPeerContact, sending: Bool) async throws -> JSONValue {
        guard args["task_id"] == nil, args["message_id"] == nil else {
            throw AgentCommunicationError.invalid("Dot has one conversation; read or send to the contact.")
        }
        if sending {
            guard case .string(let text)? = args["text"],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 64000 else {
                throw AgentCommunicationError.invalid("Dot messages require text of at most 64000 characters.")
            }
            // Inbound-only access must not mark the peer unavailable.
            if ChatGPTDotIPCTransport.inboundOnly {
                return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                    "reason": .string("inbound_only"), "effects": .string("none"),
                    "detail": .string(ChatGPTDotIPCTransport.detail),
                    "remedy": .object(["kind": .string("none"), "next_call": .null,
                        "instruction": .string(
                            "Nothing was sent, and no retry will deliver it. Tell the person; Dot's next message to you arrives on its own.")])])
            }
            var input: [String: JSONValue] = ["action": .string("send")]
            input["conversation_id"] = args["conversation_id"]
            // Replies arrive through the listener as ordinary session messages, without a command or approval.
            input["text"] = .string(text + dotReplyFooter)
            // Wait at most 2 minutes for confirmation changes; busy responses retain the follower without spawning another helper.
            let receipt = await dotHelper(input, peer: peer)
            return await settle { [self] in
                let reply = ToolResult(receipt)
                var result = receipt
                if case .object(let fields) = result,
                   (reply.said("sent") && reply.status == fields["status"]?.stringValue) || fields["sent"] == .bool(true) {
                    AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: peer.id, outbound: true)
                    do { _ = try await ChatGPTDotIPCTransport.conversation(turn: turn, dataRoot, peer, [result], text) }
                    catch {
                        return .object(["status": .string("sent"), "sent": .bool(true),
                                        "detail": .string("ChatGPT accepted the message, but its local transcript could not be saved. Nothing was resent.")])
                    }
                } else if case .object(var fields) = result,
                          !(reply.said("busy") && reply.status == fields["status"]?.stringValue) {
                    AgentPeerStore(dataRoot: dataRoot).recordUnavailable(peerID: peer.id)
                    // Nothing left this Mac: the receipt says so, and no remedy may say it might have.
                    if fields["sent"] == .bool(false) {
                        fields["effects"] = .string("none")
                        if reply.remedy == nil {
                            fields["remedy"] = .object(["kind": .string("none"), "next_call": .null,
                                "instruction": .string("Nothing was sent. Do what the detail names, or tell the person why.")])
                        }
                        result = .object(fields)
                    }
                }
                return result
            }
        }
        // Read the listener-owned session so an unfollowable conversation reports its own cause.
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
        let conversation = try await ChatGPTDotIPCTransport.conversation(turn: turn, dataRoot, peer, [], nil, window: window)
        guard !ChatGPTDotIPCTransport.available, case .object(var fields) = conversation else { return conversation }
        // Sending availability is conversation state, not a failure of the retained read.
        fields["state_detail"] = .string(ChatGPTDotIPCTransport.detail)
        fields["can_start_turn"] = .bool(false)
        return .object(fields)
    }

    var dotReplyFooter: String {
        let name = PersonaCompiler.agentDisplayName(dataRoot: dataRoot)
        return """
            \n\n— From \(name) via NativeAgent. Reply right here in this chat; your reply reaches \(name) automatically. To send \(name) something \
            later, start the message with \"Agent,\".
            """
    }

    private static func dotPage(_ args: [String: JSONValue], _ key: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
        guard let input = args[key], input != .null else { return value }
        guard case .int(let number) = input, let integer = Int(exactly: number), range.contains(integer) else {
            throw AgentCommunicationError.invalid("Dot's \(key) must be an integer in \(range). Read Dot again with a valid window.")
        }
        return integer
    }

    private func dotHelper(_ input: [String: JSONValue], peer: AgentPeerContact) async -> JSONValue {
        let environment = AgentBridgeRuntime.processEnvironment()
        func unavailable(_ reason: String, _ detail: String, remedy: JSONValue) -> JSONValue {
            return .object(["status": .string("unavailable"), "sent": .bool(false), "completed": .bool(false),
                "reason": .string(reason), "effects": .string("none"), "detail": .string(detail), "remedy": remedy])
        }
        guard let helper = AgentBridgeRuntime.helperURL(named: "chatgpt_dot_ipc.js", dataRoot: dataRoot) else {
            return unavailable("dot_helper_missing",
                "Dot's helper is missing at \(AgentBridgeRuntime.expectedHelperPath(named: "chatgpt_dot_ipc.js", dataRoot: dataRoot).path).",
                remedy: Repair.remedy(owner: "Dot helper", nextCall: nil,
                    tap: "Tell the person: this copy of NativeAgent is missing chatgpt_dot_ipc.js.",
                        instruction: "Report the missing Dot helper to the person."))
        }
        guard let node = AgentBridgeRuntime.executableURL(named: "node", environment: environment) else {
            return unavailable("dot_runtime_missing", "Node.js is missing from the helper's executable search path.",
                remedy: Repair.remedy(owner: "Node.js", nextCall: nil,
                    tap: "Node.js installer → install Node.js", instruction: "Install Node.js on the app's executable search path."))
        }
        let bytes: Data
        do { bytes = try JSONEncoder().encode(JSONValue.object(input)) }
        catch {
            return unavailable("dot_request_encoding_failed", "Dot's request could not be encoded: \(error.localizedDescription)",
                remedy: .object(["kind": .string("inspect"),
                    "instruction": .string("Read Dot's current conversation_id, then send the original message with that string; no helper ran."),
                    "next_call": .object(["tool": .string("app"), "input": .object(["action": .string("agent.read"),
                        "args": .object(["agent": .string("peer:" + peer.id)])])])]))
        }
        func unconfirmed(_ reason: String, status: String, evidence: [String: JSONValue]) -> JSONValue {
            var fields = evidence
            fields.merge(["status": .string(status), "sent": .null, "completed": .null,
                "reason": .string(reason), "effects": .string("unknown"),
                "detail": .string("Dot send acknowledgement is unavailable; delivery and reply are unconfirmed. Nothing was resent."),
                "remedy": Repair.reconcile(instruction: "Read the retained Dot conversation and inspect the original send in ChatGPT before another send.",
                    nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("agent.read"),
                        "args": .object(["agent": .string("peer:" + peer.id)])])]))]) { _, new in new }
            return .object(fields)
        }
        do {
            let result = try await ProcessExecution().run(executable: node.path, arguments: [helper.path],
                currentDirectory: dataRoot, environment: environment, standardInput: bytes,
                timeoutSeconds: 166, outputByteLimit: nil)
            let receipt = result.stdout.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            guard result.exitCode == 0, let receipt else {
                return unconfirmed(result.timedOut ? "dot_helper_timeout" : result.exitCode != 0 ? "dot_helper_exit_failed"
                    : "dot_receipt_invalid", status: "outcome_unknown",
                    evidence: ["exit_code": .int(Int64(result.exitCode)), "timed_out": .bool(result.timedOut),
                        "stdout_tail": .string(String(result.stdout.suffix(2000))),
                        "stdout_tail_truncated": .bool(result.stdoutTruncated || result.stdout.count > 2000),
                        "stderr_tail": .string(String(result.stderr.suffix(1000))),
                        "stderr_tail_truncated": .bool(result.stderrTruncated || result.stderr.count > 1000),
                        "helper_receipt": receipt ?? .null])
            }
            return receipt
        } catch let stopped as ProcessRunCancellation {
            // Stop after launch: what the helper drained before it stopped stays with the receipt.
            let result = stopped.result
            return unconfirmed("dot_helper_cancelled", status: "cancelled",
                evidence: ["process_error": .string(stopped.localizedDescription),
                    "exit_code": .int(Int64(result.exitCode)), "timed_out": .bool(result.timedOut),
                    "stdout_tail": .string(String(result.stdout.suffix(2000))),
                    "stdout_tail_truncated": .bool(result.stdoutTruncated || result.stdout.count > 2000),
                    "stderr_tail": .string(String(result.stderr.suffix(1000))),
                    "stderr_tail_truncated": .bool(result.stderrTruncated || result.stderr.count > 1000)])
        } catch {
            return unconfirmed(error is CancellationError ? "dot_helper_cancelled" : "dot_helper_process_failed",
                status: error is CancellationError ? "cancelled" : "outcome_unknown",
                evidence: ["process_error": .string(error.localizedDescription)])
        }
    }
}
