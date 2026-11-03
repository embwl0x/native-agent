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
// Blueprint: | `ConversationPrefixSeeding.swift` | One provider-independent user-leading context delivery; ordered paragraph replacements from the preceding replayed complete state, keyframes, sent-row metadata and full/delta byte telemetry; bounded exact-input diagnostic preview reuse keeps unchanged history redaction off subsequent dispatches |

/// historyMessages ‖ [user: sent context block, current words].
/// Every provider gets the same layout. Earlier blocks remain exactly as sent
/// on their user rows; changes replace paragraphs of the preceding state. A route/window
/// change or loss of the last full block starts a new keyframe.
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

    /// The request and its count leave the same builder, after codec layout.
    static func request(_ context: TurnContext, codec: ToolCallCodec) throws -> Request {
        let seed = seed(context, textToolCatalogAppendix: codec == .textMarkers
            ? try TextMarkerCodec.volatileCatalogAppendix(for: context) : nil)
        let layout = codec == .textMarkers
            ? try TextMarkerCodec.systemLayout(baseSystem: seed.context.systemPrompt,
                segments: seed.context.systemSegments, context: seed.context)
            : (system: seed.context.systemPrompt ?? "", segments: seed.context.systemSegments)
        let names = ProviderToolNameMap(seed.context.toolSchemas)
        return Request(seed: seed, system: layout.system, segments: layout.segments,
            tools: codec.requestTools(names.schemas))
    }

    /// Nudges append to the trailing user message without changing prior blocks.
    static func appendUserText(_ text: String, to conversation: inout [LLMMessage]) {
        if let last = conversation.last, last.role == .user {
            conversation[conversation.count - 1] = LLMMessage(role: .user, content: last.content + [.text(text)])
        } else { conversation.append(.user(text)) }
    }

    /// PERMANENT DIAGNOSTIC: a short digest of ONE message — its role plus its
    /// serialized content — so head drift is visible in the trace.
    ///
    /// Sizes are blind to this failure: two different first messages have the
    /// same length, so `historyMessageChars` looks stable while the provider
    /// re-reads everything. Twelve hex characters is enough to compare two
    /// turns' rows by eye and far too little to reconstruct content from.
    static func messageDigest(_ message: LLMMessage) -> String {
        var hasher = SHA256()
        SwiftNativeTurnEngine.updateFingerprint(&hasher, label: "role", data: Data(message.role.rawValue.utf8))
        for (index, block) in message.content.enumerated() {
            SwiftNativeTurnEngine.updateFingerprint(&hasher, label: "b\(index)", block: block)
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// How many leading messages carry a digest. Six covers the head — where
    /// drift actually shows — without turning a trace row into a transcript.
    static let messageDigestCount = 6

    /// SHA-256 over everything that must be byte-identical from one turn to the
    /// next for a provider prefix cache to hit: the stable segments, the tool
    /// contract, and every message STRICTLY BEFORE the volatile block.
    ///
    /// Sizes and digests only — no prompt content ever leaves this function.
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

    /// One labelled component digest. Same length-prefixed feed as
    /// `prefixFingerprint` so a component hash cannot be confused with a
    /// concatenation of its neighbours. Sizes and digests only.
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

    /// Fingerprint + size receipts for one seeded turn, published to the turn
    /// trace and the `llm.call` row. Payload-free.
    static func telemetry(
        _ seed: Seed,
        toolSchemaFingerprint: String
    ) -> ConversationPrefixTelemetrySnapshot {
        // "What the next turn can reuse": history through the previous
        // assistant. The CURRENT user message is per-turn content and is
        // excluded — including it would make the fingerprint change every turn
        // by construction and measure nothing.
        let before = Array(seed.messages.prefix(seed.currentUserIndex))
        let digests = seed.messages.prefix(max(messageDigestCount, before.count)).map(messageDigest)
        let segments = seed.context.systemSegments
        // TEXT-COMPAT lane: only the always-on FLOOR is inside the cached
        // prefix — the session-loaded run rides the volatile block. Hashing the
        // whole schema set here would report a moved prefix on every
        // tool_load/promotion the layout deliberately stopped moving, which is
        // the instrument lying about the exact fix it is measuring.
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
