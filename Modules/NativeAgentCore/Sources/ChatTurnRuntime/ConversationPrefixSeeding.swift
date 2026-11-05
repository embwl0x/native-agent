import ChatToolParsing
import ChatSessionWork
import Privacy
import Foundation
import Context
import MemoryV2
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Synchronization
// Blueprint: | `ConversationPrefixSeeding.swift` | User-leading deltas, keyframes and exact sent-row metadata |

/// Every provider shares the same user-leading layout; preserve prior blocks exactly as sent.
/// A route/window change or missing full block starts a keyframe so paragraph deltas retain a valid base.
enum ConversationPrefixSeeding {
    private struct PreviewKey: Hashable, Sendable {
        let bytes: Data
        let limit: Int
    }
    private static let previews = Mutex<(rows: [PreviewKey: String], bytes: Int)>(([:], 0))
    private static let previewMaximumBytes = 8 * 1024 * 1024
    enum VolatileDelivery: String, Sendable, Equatable {
        case userLeadingBlock
        case none
    }

    struct Seed: Sendable {
        let context: TurnContext
        let messages: [LLMMessage]
        let delivery: VolatileDelivery
        /// Everything before this index is the reusable history prefix.
        let currentUserIndex: Int
        let textToolCatalogRidesVolatileBlock: Bool
        let sentContext: SentTurnContext
        let fullBlockBytes: Int
    }

    /// The text lane's session catalog belongs with the changing block, while
    /// its always-on floor remains in the stable system material.
    static func seed(_ ctx: TurnContext, textToolCatalogAppendix: String? = nil) -> Seed {
        var split = ctx.splittingVolatileBlock(appending: textToolCatalogAppendix ?? "")
        let full = split.turnVolatileBlock ?? ""
        let request = SessionRequestMessages.seed(history: split.historyMessages,
            replayed: split.replayedTurnContexts, fullBlock: full, model: split.modelId,
            provider: split.providerId, window: split.historyContextWindow, userText: split.userMessage,
            images: split.imageBlocks)
        let sent = request.sent
        split.turnVolatileBlock = sent.block
        return Seed(context: split, messages: request.messages,
            delivery: sent.block.isEmpty ? .none : .userLeadingBlock,
            currentUserIndex: request.currentUserIndex,
            textToolCatalogRidesVolatileBlock: textToolCatalogAppendix != nil,
            sentContext: sent, fullBlockBytes: full.utf8.count)
    }

    struct Request: Sendable {
        let seed: Seed
        let system: String?
        let segments: SystemPromptSegments?
        let tools: [LLMToolSchema]?
        var additionalMessages: [LLMMessage] = []
        var messages: [LLMMessage] {
            var result = seed.messages
            for message in additionalMessages {
                if let last = result.last, last.role == message.role {
                    result[result.count - 1] = LLMMessage(role: last.role, content: last.content + message.content)
                } else { result.append(message) }
            }
            return result
        }
        func appending(_ messages: [LLMMessage]) -> Self {
            var result = self
            result.additionalMessages = messages
            return result
        }
        func plan(runID: String, userMessageID: String?, additionalCharacters: Int = 0) throws -> SessionContextPlan {
            guard let replay = seed.context.historyReplaySpec else {
                throw ProviderRoutingError.configurationFailed("This conversation's request has no replay builder.")
            }
            return SessionContextPlan(replay: replay, currentRunID: runID, currentUserMessageID: userMessageID,
                systemAndToolsCharacters: LLMMessage.inputCharacters([], system: system, tools: tools ?? []),
                additionalCharacters: additionalCharacters, model: seed.context.modelId, provider: seed.context.providerId)
        }
        var measurement: SessionContextRequest {
            get throws { try SessionContextRequest(messages: messages, system: system, tools: tools ?? [],
                historyCharacters: LLMMessage.inputCharacters(seed.context.historyMessages, system: nil, tools: []),
                rowCharacters: seed.context.historyRowCharacters) }
        }
    }

    // Preserve the current turn while replacing only its prior-history prefix.
    static func additionalMessages(in messages: [LLMMessage], after seed: Seed) throws -> [LLMMessage] {
        let index = seed.currentUserIndex
        guard messages.indices.contains(index), seed.messages.indices.contains(index),
              messages[index].content.count >= seed.messages[index].content.count else {
            throw ProviderRoutingError.configurationFailed("The request no longer contains its built user block.")
        }
        let added = Array(messages[index].content.dropFirst(seed.messages[index].content.count))
        var additional = added.isEmpty ? [] : [LLMMessage(role: .user, content: added)]
        additional.append(contentsOf: messages.dropFirst(index + 1))
        return additional
    }

    /// The request and its count leave the same builder, after codec layout.
    static func request(_ context: TurnContext, codec: ToolCallCodec, turn: Turn?) throws -> Request {
        let seed = seed(context, textToolCatalogAppendix: codec == .textMarkers
            ? try TextMarkerCodec.volatileCatalogAppendix(for: context) : nil)
        let layout = codec == .textMarkers
            ? try TextMarkerCodec.systemLayout(baseSystem: seed.context.systemPrompt,
                segments: seed.context.systemSegments, context: seed.context, turn: turn)
            : (system: seed.context.systemPrompt ?? "", segments: seed.context.systemSegments)
        let names = ProviderToolNameMap(seed.context.toolSchemas)
        return Request(seed: seed, system: layout.system, segments: layout.segments,
            tools: codec.requestTools(names.schemas))
    }

    /// Nudges append to the trailing user message without changing prior blocks.
    static func appendUserText(_ text: String, to conversation: inout [LLMMessage]) {
        appendUser([.text(text)], to: &conversation)
    }

    static func appendUser(_ blocks: [LLMContentBlock], to conversation: inout [LLMMessage]) {
        if let last = conversation.last, last.role == .user {
            conversation[conversation.count - 1] = LLMMessage(role: .user, content: last.content + blocks)
        } else { conversation.append(LLMMessage(role: .user, content: blocks)) }
    }

    /// Role-and-content digests reveal prefix drift that equal sizes cannot. Twelve hex characters permit comparison without retaining prose.
    static func messageDigest(_ message: LLMMessage) -> String {
        var hasher = SHA256()
        SwiftNativeTurnEngine.updateFingerprint(&hasher, label: "role", data: Data(message.role.rawValue.utf8))
        for (index, block) in message.content.enumerated() {
            SwiftNativeTurnEngine.updateFingerprint(&hasher, label: "b\(index)", block: block)
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// Six messages cover prefix-head drift without turning the trace into a transcript.
    static let messageDigestCount = 6

    /// Hash stable material, the tool contract and messages before the volatile block to measure reusable provider prefixes.
    /// Only sizes and digests leave this boundary; no prompt content.
    static func prefixFingerprint(
        stable: String,
        toolSchemaFingerprint: String,
        messagesBeforeVolatile: [LLMMessage]
    ) -> String {
        var hasher = SHA256()
        SwiftNativeTurnEngine.updateFingerprint(&hasher, label: "stable", data: Data(stable.utf8))
        // The empty labelled component preserves the telemetry digest format.
        SwiftNativeTurnEngine.updateFingerprint(&hasher, label: "stableSuffix", data: Data())
        SwiftNativeTurnEngine.updateFingerprint(&hasher, label: "tools", data: Data(toolSchemaFingerprint.utf8))
        for (index, message) in messagesBeforeVolatile.enumerated() {
            SwiftNativeTurnEngine.updateFingerprint(&hasher, label: "m\(index).role", data: Data(message.role.rawValue.utf8))
            for (blockIndex, block) in message.content.enumerated() {
                SwiftNativeTurnEngine.updateFingerprint(&hasher, label: "m\(index).b\(blockIndex)", block: block)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Length-prefix labelled components so their digest cannot collide structurally with concatenated neighbors.
    static func componentFingerprint(_ label: String, _ parts: [String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(label.utf8.count):\(label)".utf8))
        for part in parts {
            let bytes = Data(part.utf8)
            hasher.update(data: Data("\(bytes.count):".utf8))
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Redact the whole string before capping its single-line trace preview so partial secrets cannot survive.
    static func tracePreview(_ text: String, limit: Int) -> String {
        let key = PreviewKey(bytes: Data(text.utf8), limit: limit)
        if let kept = previews.withLock({ $0.rows[key] }) { return kept }
        let preview = String(
            NativeAgentSecretRedactor.redactText(text)
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(limit)
        )
        if key.bytes.count <= previewMaximumBytes {
            previews.withLock { memo in
                guard memo.rows[key] == nil else { return }
                if memo.rows.count >= 64 || memo.bytes + key.bytes.count > previewMaximumBytes {
                    memo = ([:], 0)
                }
                memo.rows[key] = preview
                memo.bytes += key.bytes.count
            }
        }
        return preview
    }

    /// Trace only seeded sizes and fingerprints, never prompt payloads.
    static func telemetry(
        _ seed: Seed,
        toolSchemaFingerprint: String
    ) -> ConversationPrefixTelemetrySnapshot {
        // Exclude the current user message so per-turn content does not make the reusable-prefix fingerprint change every turn.
        let before = Array(seed.messages.prefix(seed.currentUserIndex))
        let digests = seed.messages.prefix(max(messageDigestCount, before.count)).map(messageDigest)
        let segments = seed.context.systemSegments
        // Text-compat prefixes cache only the always-on floor; volatile session schemas must not make that fingerprint drift.
        let prefixToolFingerprint = seed.textToolCatalogRidesVolatileBlock
            ? SwiftNativeTurnEngine.toolSchemaFingerprint(
                seed.context.toolSchemas.filter {
                    SwiftToolDispatcher.alwaysOnCoreNames.contains($0.name)
                }
            )
            : toolSchemaFingerprint
        return ConversationPrefixTelemetrySnapshot(
            shapeVersion: "v2Prefix",
            prefixFingerprintSHA256: prefixFingerprint(
                stable: segments?.stable ?? seed.context.systemPrompt ?? "",
                toolSchemaFingerprint: prefixToolFingerprint,
                messagesBeforeVolatile: before
            ),
            historyMessageCount: seed.context.historyMessages.count,
            historyMessageChars: seed.context.historyMessages.reduce(0) { total, message in
                total + message.content.reduce(0) {
                    if case .text(let text) = $1 { return $0 + text.count }
                    return $0
                }
            },
            volatileBlockChars: seed.context.turnVolatileBlock?.count ?? 0,
            volatileFullBlockBytes: seed.fullBlockBytes,
            volatileDeltaBlockBytes: seed.sentContext.block.utf8.count,
            volatileKeyframe: seed.sentContext.isKeyframe,
            volatileDelivery: seed.delivery.rawValue,
            historyContextWindow: seed.context.historyContextWindow,
            messageCount: seed.messages.count,
            messageDigests: Array(digests.prefix(messageDigestCount)),
            prefixMessageDigests: Array(digests.prefix(before.count)),
            // Component fingerprints identify which part of the request changed.
            stablePrefixFingerprintSHA256: Self.componentFingerprint(
                "stablePrefix",
                [segments?.stable ?? seed.context.systemPrompt ?? "", ""]
            ),
            toolsFingerprintSHA256: prefixToolFingerprint,
            historyHeadFingerprintSHA256: Self.componentFingerprint(
                "historyHead", Array(digests.prefix(min(4, before.count)))),
            // Redact complete text before truncation so a split credential cannot escape recognition.
            headPreviews: (before.prefix(4).map { message in
                let text = message.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }.joined(separator: " ")
                return "\(message.role.rawValue): " + Self.tracePreview(text, limit: 64)
            }) + (before.count > 1 ? before[1].content.prefix(16).enumerated().map { index, block -> String in
                if case .text(let t) = block {
                    return "m1.\(index)[\(t.count)]: " + Self.tracePreview(t, limit: 48)
                }
                return "m1.\(index): <non-text>"
            } : []) + [],
        )
    }
}
