import AgentWorkspace
import Foundation
import NativeAgentShared
import Darwin
import CryptoKit
import NativeAgentCore
import PersistenceCore
import Desk
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import MacIntegration
import ToolRegistry
// Blueprint: | `SwiftToolDispatcher+BuilderConversation.swift` | `SwiftToolDispatcher`: builder conversation handles, topic spelling and inbox/wake/receipt projections |

extension SwiftToolDispatcher {
    /// Handles reference CLI-owned state: Codex threads and Claude/OMP topic pointers.
    /// NativeAgent neither copies transcripts nor creates a second session store.
    enum BuilderConversationAgent: String {
        case codex
        case claude
        case omp
    }

    struct BuilderConversationSelection {
        let conversationId: String?
        let resumeId: String?
        let topic: String?

        func inboxFields(messageId: String, queuedAt: String, priority: String, text: String,
                         sessionId: String, origin: JSONValue, workingDirectory: String?,
                         deskHandle: String?) -> [String: JSONValue] {
            var fields: [String: JSONValue] = [
                "id": .string(messageId), "messageId": .string(messageId),
                "createdAt": .string(queuedAt), "from": .string("assistant"),
                "priority": .string(priority), "text": .string(text),
                "read": .bool(false), "origin": origin,
            ]
            if let topic { fields["topic"] = .string(topic) }
            if let conversationId { fields["conversationId"] = .string(conversationId) }
            if !sessionId.isEmpty { fields["sessionId"] = .string(sessionId) }
            if let workingDirectory { fields["workingDirectory"] = .string(workingDirectory) }
            if let deskHandle { fields["deskHandle"] = .string(deskHandle) }
            return fields
        }

        func wakeFields(entry: [String: JSONValue], agent: BuilderConversationAgent,
                        queuedAt: String, inboxPath: String) -> [String: JSONValue] {
            var fields = entry.filter {
                ["messageId", "text", "priority", "topic", "sessionId", "origin", "workingDirectory",
                 "deskHandle", "brain", "model", "reasoningEffort", "serviceTier", "fast",
                 "executionProfile", "pairReviewer", "completionMode", "timeoutSeconds",
                 "requireExistingConversation"].contains($0.key)
            }
            fields["queuedAt"] = .string(queuedAt)
            fields["inboxPath"] = .string(inboxPath)
            fields["source"] = .string("\(agent.rawValue)_message")
            if agent == .codex, let resumeId { fields["threadId"] = .string(resumeId) }
            if agent == .omp { fields["cwd"] = fields.removeValue(forKey: "workingDirectory") }
            SwiftToolDispatcher.stampDelegationProducer(on: &fields)
            return fields
        }

        func queuedReceipt(entry: [String: JSONValue], filePath: String, queuedAt: String,
                           deduplicated: Bool, replyWith: String) -> [String: JSONValue] {
            var fields = entry.filter {
                ["messageId", "priority", "workingDirectory", "deskHandle", "conversationId"].contains($0.key)
            }
            fields["status"] = .string("queued")
            fields["filePath"] = .string(filePath)
            fields["queuedAt"] = .string(queuedAt)
            fields["deduplicated"] = .bool(deduplicated)
            if conversationId != nil { fields["replyWith"] = .string(replyWith) }
            return fields
        }
    }

    enum BuilderConversationMode: String, Equatable {
        case new
        case resume
    }

    enum BuilderConversationReferenceError: Error {
        case malformed(expectedAgent: BuilderConversationAgent)
        case invalidMode
        case modeConflict(mode: BuilderConversationMode)
        case agentMismatch(expected: BuilderConversationAgent, actual: String)
        case topicMismatch(conversationId: String, topic: String)

        var envelope: JSONValue {
            switch self {
            case .malformed(let expectedAgent):
                return .object([
                    "status": .string("failed"), "effects": .string("none"),
                    "reason": .string("invalid_conversation_id"),
                    "fix": .string("Pass the exact \(expectedAgent.rawValue):… conversationId returned by the first builder message."),
                ])
            case .invalidMode:
                return .object([
                    "status": .string("failed"), "effects": .string("none"),
                    "reason": .string("invalid_conversation_mode"),
                    "fix": .string("Use conversation_mode='new' with no conversation_id, or conversation_mode='resume' with the exact returned conversationId."),
                ])
            case .modeConflict(let mode):
                return .object([
                    "status": .string("failed"), "effects": .string("none"),
                    "reason": .string("conversation_mode_conflict"),
                    "conversationMode": .string(mode.rawValue),
                    "fix": .string(mode == .new
                        ? "Remove conversation_id when starting new work."
                        : "Pass the exact conversationId returned by the earlier builder message when resuming."),
                ])
            case .agentMismatch(let expected, let actual):
                return .object([
                    "status": .string("failed"), "effects": .string("none"),
                    "reason": .string("conversation_agent_mismatch"),
                    "expectedAgent": .string(expected.rawValue),
                    "actualAgent": .string(actual),
                    "fix": .string("Reply with the same builder tool that created this conversation."),
                ])
            case .topicMismatch(let conversationId, let topic):
                return .object([
                    "status": .string("failed"), "effects": .string("none"),
                    "reason": .string("conversation_topic_mismatch"),
                    "conversationId": .string(conversationId),
                    "topic": .string(topic),
                    "fix": .string("topic must match conversation_id; pass topic: \"\(conversationId.split(separator: ":", maxSplits: 1).last ?? "")\" or omit topic."),
                ])
            }
        }
    }

    /// Selection and worktree follow-up admission both treat an empty conversation_id as absent.
    static func builderConversationReferenceSupplied(in input: [String: JSONValue]) -> Bool {
        guard case .string(let raw)? = input["conversation_id"] else {
            // Selection rejects malformed non-null values before follow-up admission.
            return input["conversation_id"] != nil && input["conversation_id"] != .null
        }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func builderConversationSelection(
        input: [String: JSONValue],
        agent: BuilderConversationAgent,
        topic: String?,
        messageId: String
    ) -> Result<BuilderConversationSelection, BuilderConversationReferenceError> {
        let requestedMode: BuilderConversationMode?
        if let rawMode = input["conversation_mode"], rawMode != .null {
            guard case .string(let raw) = rawMode else {
                return .failure(.invalidMode)
            }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty {
                requestedMode = nil
            } else {
                guard let mode = BuilderConversationMode(rawValue: normalized) else {
                    return .failure(.invalidMode)
                }
                requestedMode = mode
            }
        } else {
            requestedMode = nil
        }

        let suppliedReference: String?
        if let rawReference = input["conversation_id"], rawReference != .null {
            guard case .string(let raw) = rawReference else {
                return .failure(.malformed(expectedAgent: agent))
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty conversation_id means no conversation, like omission.
            suppliedReference = value.isEmpty ? nil : value
        } else {
            suppliedReference = nil
        }

        if requestedMode == .new, suppliedReference != nil {
            // A supplied handle must never silently become a different job.
            return .failure(.modeConflict(mode: .new))
        }
        if requestedMode == .resume, suppliedReference == nil {
            return .failure(.modeConflict(mode: .resume))
        }

        guard let suppliedReference else {
            if agent == .codex {
                return .success(.init(conversationId: nil, resumeId: nil, topic: topic))
            }
            let stableTopic = topic ?? "conversation-\(shortStableBuilderMessageId(messageId))"
            let slug = builderTopicSlug(stableTopic)
            return .success(.init(
                conversationId: "\(agent.rawValue):\(slug)",
                resumeId: slug,
                topic: slug
            ))
        }

        let pieces = suppliedReference.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return .failure(.malformed(expectedAgent: agent)) }
        let actualAgent = String(pieces[0])
        guard actualAgent == agent.rawValue else {
            return .failure(.agentMismatch(expected: agent, actual: actualAgent))
        }
        let resumeId = String(pieces[1])
        guard !resumeId.isEmpty, resumeId.count <= 160,
              resumeId.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (48...57).contains(value)
                      || (65...90).contains(value)
                      || (97...122).contains(value)
                      || scalar == "-" || scalar == "_" || scalar == "."
              }) else {
            return .failure(.malformed(expectedAgent: agent))
        }

        if agent != .codex {
            guard builderTopicSlug(resumeId) == resumeId else {
                return .failure(.malformed(expectedAgent: agent))
            }
            if let topic, builderTopicSlug(topic) != resumeId {
                return .failure(.topicMismatch(conversationId: suppliedReference, topic: topic))
            }
        }
        return .success(.init(
            conversationId: suppliedReference,
            resumeId: resumeId,
            topic: agent == .codex ? topic : resumeId
        ))
    }

    /// Match wake-helper topicSlug: lowercase ASCII alphanumerics, collapsed dashes, 64 characters.
    static func builderTopicSlug(_ raw: String) -> String {
        var output = ""
        var pendingSeparator = false
        for scalar in raw.lowercased().unicodeScalars {
            let value = scalar.value
            let isASCIIAlphaNumeric = (48...57).contains(value) || (97...122).contains(value)
            if isASCIIAlphaNumeric {
                if pendingSeparator, !output.isEmpty { output.append("-") }
                pendingSeparator = false
                output.unicodeScalars.append(scalar)
            } else if !output.isEmpty {
                pendingSeparator = true
            }
        }
        let canonical = String(output.prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return canonical.isEmpty ? "general" : canonical
    }

    private static func shortStableBuilderMessageId(_ messageId: String) -> String {
        SHA256.hash(data: Data(messageId.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
