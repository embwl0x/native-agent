import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace

// Blueprint: | `TurnContextSnapshotTrace.swift` | `SwiftNativeTurnEngine.fireContextSnapshotEvent`: local bounded, redacted context snapshots and prompt/schema fingerprints tied to the current turn trace |
// v2Prefix receipts (ConversationPrefixTelemetry).
import ProviderRouting
// ContextFlow packet provenance, for the memory-recall outcome on packet turns.
import Context

// MARK: - Turn Inspector context snapshots

extension SwiftNativeTurnEngine {
    private static let contextSnapshotChunkChars = 1_800
    private static let contextSnapshotStableLimit = 48_000
    private static let contextSnapshotDynamicLimit = 32_000
    private static let contextSnapshotSystemLimit = 48_000
    private static let contextSnapshotUserLimit = 8_000
    private static let contextSnapshotCognitiveLimit = 12_000
    private static let contextSnapshotToolLimit = 160

    /// Emit the model-visible turn context for local inspection.
    ///
    /// This is intentionally separate from `assembly.stage`, which remains
    /// sizes-only. The snapshot event is still local, bounded, redacted, and
    /// tied to the current `TurnTraceContext.turnId`; if no turn is bound it is
    /// dropped by `TurnTraceBus.fireFromContext`. An empty recall with no
    /// explicit outcome stays `unknown`; this seam never guesses that a
    /// swallowed recall failure was a legitimate zero-hit result. Returns the
    /// session id the snapshot was filed under, for the turn's later milestones.
    @discardableResult
    nonisolated static func fireContextSnapshotEvent(
        surface: String,
        context: TurnContext,
        sessionId: String? = nil,
        runId: String? = nil
    ) -> String? {
        let segments = context.systemSegments
        let systemPrompt = context.systemPrompt ?? segments?.combined ?? ""
        let stable = segments?.stable ?? ""
        // Per-turn material may travel in the user block instead of system segments.
        let volatileBlock = context.turnVolatileBlock ?? ""
        let ridesVolatileBlock = !volatileBlock.isEmpty
        let dynamic = ridesVolatileBlock ? volatileBlock : (segments?.dynamic ?? "")
        let cognitive = context.cognitiveRuntimeContext.flatMap { fragment in
            Self.deliveredInput(context).contains(fragment) ? fragment : nil
        }
        let sourceSizes = context.personaDocs.keys.sorted().map { id in
            let content = context.personaDocs[id] ?? ""
            return JSONValue.object([
                "source": .string(id),
                "chars": .int(Int64(content.count)),
                "bytes": .int(Int64(content.utf8.count)),
            ])
        }
        let schemaSizes = context.toolSchemas.map { schema in
            let nameBytes = schema.name.utf8.count
            let descriptionBytes = schema.description.utf8.count
            let parameterBytes = schema.parametersJSON.count
            return JSONValue.object([
                "name": .string(schema.name),
                "nameBytes": .int(Int64(nameBytes)),
                "descriptionBytes": .int(Int64(descriptionBytes)),
                "parameterBytes": .int(Int64(parameterBytes)),
                "materialBytes": .int(Int64(nameBytes + descriptionBytes + parameterBytes)),
            ])
        }
        let sourceBytes = context.personaDocs.values.reduce(0) { $0 + $1.utf8.count }
        let toolSchemaParameterBytes = context.toolSchemas.reduce(0) {
            $0 + $1.parametersJSON.count
        }
        let toolSchemaMaterialBytes = context.toolSchemas.reduce(0) {
            $0 + $1.name.utf8.count + $1.description.utf8.count + $1.parametersJSON.count
        }
        let systemBytes = systemPrompt.utf8.count
        let stableBytes = stable.utf8.count
        let dynamicBytes = dynamic.utf8.count
        let userMessageBytes = context.userMessage.utf8.count
        let cognitiveBytes = cognitive?.utf8.count ?? 0
        let imagePayloadBytes = context.imageBlocks.reduce(0) { partial, block in
            guard case .image(_, _, _, let byteSize) = block else { return partial }
            return partial + max(0, byteSize)
        }
        // On a ContextFlow-active turn the legacy `recalled` lane is empty BY
        // DESIGN — memory arrives inside the packet — so falling straight to
        // `.unknown` reported "we have no idea" about a turn whose memory
        // provenance is fully known. Derive the same `.contextFlow` outcome
        // `buildTurnContext` already stamps on the stage trace, from the same
        // packet, so the two receipts agree.
        let contextFlowMemoryAtoms = context.fluidContextTurn.map { prepared in
            prepared.packet.selectedItems.reduce(into: 0) {
                if $1.pointer.kind == .memory || $1.pointer.kind == .correction { $0 += 1 }
            }
        }
        let resolvedMemoryRecallOutcome: MemoryRecallTraceOutcome = {
            if !context.recalled.isEmpty {
                return .succeeded(hitCount: context.recalled.count)
            }
            if let contextFlowMemoryAtoms {
                return .contextFlow(hitCount: contextFlowMemoryAtoms)
            }
            return .unknown
        }()

        TurnLifecycleTelemetry.emit(
            .contextReady,
            surface: surface,
            sessionId: sessionId,
            observedBy: "context.snapshot.input",
            counts: [
                "systemBytes": Int64(systemBytes),
                "toolSchemaParameterBytes": Int64(toolSchemaParameterBytes),
            ]
        )

        var payload: [String: JSONValue] = [
            "schema": .string("context.snapshot.v1"),
            "model": .string(context.modelId),
            "reasoningEffort": .string(context.reasoningEffort),
            "systemTotalChars": .int(Int64(systemPrompt.count)),
            "stableChars": .int(Int64(stable.count)),
            "dynamicChars": .int(Int64(dynamic.count)),
            "userMessageChars": .int(Int64(context.userMessage.count)),
            "toolSchemaCount": .int(Int64(context.toolSchemas.count)),
            "toolsAvailableCount": .int(Int64(context.toolsAvailable.count)),
            "recalledCount": .int(Int64(context.recalled.count)),
            "imageBlockCount": .int(Int64(context.imageBlocks.count)),
            "segmented": .bool(segments != nil),
            "containsCognitiveSubstrate": .bool(cognitive != nil),
            "personaSourceBytes": .int(Int64(sourceBytes)),
            "userBlockBytes": .int(Int64(context.personaDocs["USER"].map {
                let block = "# USER\n" + $0
                return !$0.isEmpty && systemPrompt.contains(block) ? block.utf8.count : 0
            } ?? 0)),
            "personaSources": .array(sourceSizes),
            "systemTotalBytes": .int(Int64(systemBytes)),
            "stableBytes": .int(Int64(stableBytes)),
            "dynamicBytes": .int(Int64(dynamicBytes)),
            "userMessageBytes": .int(Int64(userMessageBytes)),
            "promptTextBytes": .int(Int64(systemBytes + userMessageBytes)),
            "cognitiveCapsuleBytes": .int(Int64(cognitiveBytes)),
            "imagePayloadBytes": .int(Int64(imagePayloadBytes)),
            "toolSchemaParameterBytes": .int(Int64(toolSchemaParameterBytes)),
            "toolSchemaMaterialBytes": .int(Int64(toolSchemaMaterialBytes)),
            "toolSchemaBytes": .array(schemaSizes),
            // Injected = legacy hits ∪ packet provenance (resolvedRecalledIds);
            // `context.recalled` alone is empty on every `.active` turn.
            "memoryRecall": resolvedMemoryRecallOutcome.payload(
                injectedHitCount: context.resolvedRecalledIds.count
            ),
            "promptFingerprintSHA256": .string(promptFingerprint(
                systemPrompt: systemPrompt,
                userMessage: context.userMessage,
                imageBlocks: context.imageBlocks
            )),
            "toolSchemaFingerprintSHA256": .string(toolSchemaFingerprint(context.toolSchemas)),
            "limits": .object([
                "chunkChars": .int(Int64(contextSnapshotChunkChars)),
                "stableChars": .int(Int64(contextSnapshotStableLimit)),
                "dynamicChars": .int(Int64(contextSnapshotDynamicLimit)),
                "systemChars": .int(Int64(contextSnapshotSystemLimit)),
                "userChars": .int(Int64(contextSnapshotUserLimit)),
                "cognitiveChars": .int(Int64(contextSnapshotCognitiveLimit)),
            ]),
        ]
        if let preparationMs = context.preparationMs {
            payload["preparationMs"] = .int(preparationMs)
        }
        payload["shapeVersion"] = .string("v2Prefix")
        // One user-leading delivery on every provider. An empty delta has
        // no new block to send; its unchanged paragraphs remain in history.
        payload["volatileDelivery"] = .string(
            ridesVolatileBlock
                ? ConversationPrefixSeeding.VolatileDelivery.userLeadingBlock.rawValue
                : ConversationPrefixSeeding.VolatileDelivery.none.rawValue
        )
        let historyDelivery = context.historyMessages.isEmpty ? "none" : "messages"
        payload["historyDelivery"] = .string(historyDelivery)
        if !context.historyMessages.isEmpty || context.turnVolatileBlock != nil {
            payload["historyMessageCount"] = .int(Int64(context.historyMessages.count))
            payload["historyMessageChars"] = .int(Int64(
                context.historyMessages.reduce(0) { total, message in
                    total + message.content.reduce(0) {
                        if case .text(let text) = $1 { return $0 + text.count }
                        return $0
                    }
                }
            ))
            payload["volatileBlockChars"] = .int(Int64(context.turnVolatileBlock?.count ?? 0))
            // Bytes as well as chars, because the composer's receipt puts these
            // two lanes beside `systemTotalBytes`, `toolSchemaMaterialBytes` and
            // `userMessageBytes` and divides one by their sum. A share computed
            // across mixed units is the wrong-value-no-error class: it looks
            // like a percentage and is not one.
            payload["historyMessageBytes"] = .int(Int64(
                context.historyMessages.reduce(0) { total, message in
                    total + message.content.reduce(0) {
                        if case .text(let text) = $1 { return $0 + text.utf8.count }
                        return $0
                    }
                }
            ))
            payload["volatileBlockBytes"] = .int(Int64(volatileBlock.utf8.count))
        }
        // Text tool lane: the provider gets no tools array, so the schema JSON
        // above is never sent. Each tool rides as one prose row, the always-on
        // floor inside the system prompt and this session's loads in the turn
        // brief. Measure those rows where they actually sit, so the receipt
        // can name the tool cost without counting JSON that never left.
        if systemPrompt.contains(AnthropicOAuthTransport.textToolProtocolHeader) {
            let catalog = TextMarkerCodec.catalogSections(
                schemas: context.toolSchemas,
                names: context.toolsAvailable
            )
            func bytes(_ text: String, in host: String) -> Int {
                !text.isEmpty && host.contains(text) ? text.utf8.count : 0
            }
            payload["toolCatalogSystemBytes"] = .int(Int64(
                bytes(catalog.floor, in: systemPrompt) + bytes(catalog.appended, in: systemPrompt)
            ))
            payload["toolCatalogBriefBytes"] = .int(Int64(bytes(catalog.appended, in: volatileBlock)))
        }
        if let prefix = ConversationPrefixTelemetry.current {
            for (key, value) in prefix.payload { payload[key] = value }
        }
        if let runId, !runId.isEmpty {
            payload["runId"] = .string(runId)
        }
        if let sessionId, !sessionId.isEmpty {
            payload["sessionId"] = .string(sessionId)
        }

        if segments != nil {
            let stablePreview = snapshotPreview(stable, maxCharacters: contextSnapshotStableLimit)
            let dynamicPreview = snapshotPreview(dynamic, maxCharacters: contextSnapshotDynamicLimit)
            payload["stablePreview"] = .array(stablePreview.chunks)
            payload["dynamicPreview"] = .array(dynamicPreview.chunks)
            payload["stableTruncated"] = .bool(stablePreview.truncated)
            payload["dynamicTruncated"] = .bool(dynamicPreview.truncated)
            payload["stableRedactedChars"] = .int(Int64(stablePreview.redactedChars))
            payload["dynamicRedactedChars"] = .int(Int64(dynamicPreview.redactedChars))
            payload["segmentCount"] = .int(2)
        } else {
            let systemPreview = snapshotPreview(systemPrompt, maxCharacters: contextSnapshotSystemLimit)
            payload["systemPreview"] = .array(systemPreview.chunks)
            payload["systemTruncated"] = .bool(systemPreview.truncated)
            payload["systemRedactedChars"] = .int(Int64(systemPreview.redactedChars))
            payload["segmentCount"] = .int(1)
        }

        if let cognitive {
            payload["cognitiveCue"] = cognitiveCue(cognitive)
            let cognitivePreview = snapshotPreview(
                cognitive,
                maxCharacters: contextSnapshotCognitiveLimit
            )
            payload["cognitivePreview"] = .array(cognitivePreview.chunks)
            payload["cognitiveTruncated"] = .bool(cognitivePreview.truncated)
            payload["cognitiveRedactedChars"] = .int(Int64(cognitivePreview.redactedChars))
        }

        let userPreview = snapshotPreview(context.userMessage, maxCharacters: contextSnapshotUserLimit)
        payload["userPreview"] = .array(userPreview.chunks)
        payload["userTruncated"] = .bool(userPreview.truncated)
        payload["userRedactedChars"] = .int(Int64(userPreview.redactedChars))

        let toolNames = context.toolSchemas.isEmpty
            ? Array(context.toolsAvailable.prefix(contextSnapshotToolLimit))
            : Array(context.toolSchemas.map(\.name).prefix(contextSnapshotToolLimit))
        payload["toolNames"] = .array(toolNames.map { .string($0) })

        if !context.recalled.isEmpty {
            // Bound this recalled-hit trace slice by ContextBudgetPolicy.wideRecallRowLimit.
            payload["recalled"] = .array(context.recalled
                .prefix(ContextBudgetPolicy.wideRecallRowLimit).map { hit in
                var row: [String: JSONValue] = [
                    "preview": .array(snapshotPreview(hit.preview, maxCharacters: 1_200).chunks),
                ]
                if case .object(let extras)? = hit.extras,
                   case .string(let id)? = extras["id"],
                   !id.isEmpty {
                    row["id"] = .string(id)
                }
                return .object(row)
            })
        }

        TurnTraceBus.fireFromContext(
            kind: "context.snapshot",
            sessionId: sessionId,
            surface: surface,
            payload: .object(payload)
        )
        if let sessionId, !sessionId.isEmpty {
            ContextFedRecord.save(sessionId: sessionId, surface: surface, fed: dynamic,
                                  brief: ridesVolatileBlock ? "" : volatileBlock)
        }
        return sessionId
    }

    private nonisolated static func promptFingerprint(
        systemPrompt: String,
        userMessage: String,
        imageBlocks: [LLMContentBlock]
    ) -> String {
        var hasher = SHA256()
        updateFingerprint(&hasher, label: "system", data: Data(systemPrompt.utf8))
        updateFingerprint(&hasher, label: "user", data: Data(userMessage.utf8))
        for (index, block) in imageBlocks.enumerated() {
            let prefix = "image.\(index)"
            updateFingerprint(&hasher, label: prefix, block: block, imageLabel: prefix)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Prefix telemetry and snapshots share the same tool-contract digest.
    nonisolated static func toolSchemaFingerprint(_ schemas: [LLMToolSchema]) -> String {
        var hasher = SHA256()
        for (index, schema) in schemas.enumerated() {
            let prefix = "tool.\(index)"
            updateFingerprint(&hasher, label: prefix + ".name", data: Data(schema.name.utf8))
            updateFingerprint(
                &hasher,
                label: prefix + ".description",
                data: Data(schema.description.utf8)
            )
            updateFingerprint(&hasher, label: prefix + ".parameters", data: schema.parametersJSON)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func updateFingerprint(
        _ hasher: inout SHA256,
        label: String,
        block: LLMContentBlock,
        imageLabel: String? = nil
    ) {
        switch block {
        case .text(let text):
            updateFingerprint(&hasher, label: label + ".text", data: Data(text.utf8))
        case .toolUse(let id, let name, let inputJSON):
            updateFingerprint(&hasher, label: label + ".toolUse.id", data: Data(id.utf8))
            updateFingerprint(&hasher, label: label + ".toolUse.name", data: Data(name.utf8))
            updateFingerprint(&hasher, label: label + ".toolUse.input", data: inputJSON)
        case .toolResult(let toolUseId, let content, let isError):
            updateFingerprint(&hasher, label: label + ".toolResult.id", data: Data(toolUseId.utf8))
            updateFingerprint(&hasher, label: label + ".toolResult.content", data: Data(content.utf8))
            updateFingerprint(&hasher, label: label + ".toolResult.error", data: Data(String(isError).utf8))
        case .image(let mediaType, let base64, let name, let byteSize):
            let prefix = imageLabel ?? label + ".image"
            updateFingerprint(&hasher, label: prefix + ".mediaType", data: Data(mediaType.utf8))
            updateFingerprint(&hasher, label: prefix + ".base64", data: Data(base64.utf8))
            updateFingerprint(&hasher, label: prefix + ".name", data: Data((name ?? "").utf8))
            updateFingerprint(&hasher, label: prefix + ".byteSize", data: Data(String(max(0, byteSize)).utf8))
        }
    }

    nonisolated static func updateFingerprint(
        _ hasher: inout SHA256,
        label: String,
        data: Data
    ) {
        hasher.update(data: Data("\(label.utf8.count):\(label)\(data.count):".utf8))
        hasher.update(data: data)
    }

    private nonisolated static func cognitiveCue(_ cognitive: String) -> JSONValue? {
        let text = ChatSecretRedactor.redactText(cognitive)
            .components(separatedBy: "[OrganismBehavior]")[0]
        let lines = text.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var felt = false
        for (index, line) in lines.enumerated() {
            if line == "How you feel:" { felt = true; continue }
            let kind: String
            let wording: String
            if line.hasPrefix("- "), let colon = line.firstIndex(of: ":") {
                kind = line.dropFirst(2)[..<colon].lowercased()
                    .replacingOccurrences(of: " ", with: "_")
                wording = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else if felt {
                kind = "felt"
                wording = line
            } else { continue }
            // A Sound cue may carry its own rut nudge on the following line.
            let measured = kind == "sound"
                ? ([wording] + lines.dropFirst(index + 1).filter { $0.hasPrefix("- Sound:") })
                    .joined(separator: " ")
                : wording
            guard !measured.isEmpty else { return nil }
            return .object([
                "kind": .string(String(decoding: kind.utf8.prefix(32), as: UTF8.self)),
                "line": .string(String(decoding: measured.utf8.prefix(120), as: UTF8.self)),
                "truncated": .bool(measured.utf8.count > 120),
            ])
        }
        return nil
    }

    private nonisolated static func snapshotPreview(
        _ raw: String,
        maxCharacters: Int
    ) -> (chunks: [JSONValue], truncated: Bool, redactedChars: Int) {
        let redacted = ChatSecretRedactor.redactText(raw)
        let truncated = redacted.count > maxCharacters
        var capped = truncated ? String(redacted.prefix(maxCharacters)) : redacted
        if truncated {
            capped += "\n...[snapshot truncated \(redacted.count - maxCharacters) chars]"
        }
        return (
            chunks: chunked(capped, chunkChars: contextSnapshotChunkChars).map { .string($0) },
            truncated: truncated,
            redactedChars: redacted.count
        )
    }

    private nonisolated static func chunked(_ text: String, chunkChars: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let end = text.index(cursor, offsetBy: chunkChars, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[cursor..<end]))
            cursor = end
        }
        return chunks
    }
}


/// What a conversation's latest turn was fed, whole: the changing part of the
/// system prompt (pinned facts, recalled memories, inner state, clock) and any
/// turn brief. The trace keeps a preview; this keeps the text, one small file
/// per conversation, overwritten each turn, so the composer can show it.
public enum ContextFedRecord {
    public struct Record: Codable, Sendable {
        public let at: Date
        public let surface: String
        public let fed: String
        public let brief: String
    }

    static func url(sessionId: String, dataRoot: URL) -> URL? {
        guard let safe = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else { return nil }
        return dataRoot.appendingPathComponent("diagnostics/fed", isDirectory: true)
            .appendingPathComponent(safe + ".json")
    }

    static func save(sessionId: String, surface: String, fed: String, brief: String,
                     dataRoot: URL = defaultDataRoot()) {
        guard let url = url(sessionId: sessionId, dataRoot: dataRoot) else { return }
        let record = Record(at: Date(), surface: surface, fed: fed, brief: brief)
        DispatchQueue.global(qos: .utility).async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(record) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    public static func load(sessionId: String, dataRoot: URL) -> Record? {
        guard let url = url(sessionId: sessionId, dataRoot: dataRoot),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }
}
