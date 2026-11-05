import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace

// Blueprint: | `TurnContextSnapshotTrace.swift` | Exact opening-request snapshots and ordered fed-context writes |
import ProviderRouting
// Packet turns retain their own memory provenance for recall-outcome reporting.
import Context

// MARK: - Turn Inspector context snapshots

extension SwiftNativeTurnEngine {
    /// Cheap lifecycle boundary; snapshot redaction and local persistence may
    /// run beside dispatch without moving the meaning of context.ready.
    nonisolated static func fireContextReady(surface: String, context: TurnContext, sessionId: String?, turn: Turn) {
        TurnLifecycleTelemetry.emit(.contextReady, surface: surface, sessionId: sessionId,
            observedBy: "context.snapshot.input", counts: [
                "systemBytes": Int64((context.systemPrompt ?? context.systemSegments?.combined ?? "").utf8.count),
                "toolSchemaParameterBytes": Int64(context.toolSchemas.reduce(0) { $0 + $1.parametersJSON.count })], turn: turn)
    }
    private static let contextSnapshotChunkChars = 1_800
    private static let contextSnapshotStableLimit = 48_000
    private static let contextSnapshotDynamicLimit = 32_000
    private static let contextSnapshotSystemLimit = 48_000
    private static let contextSnapshotUserLimit = 8_000
    private static let contextSnapshotCognitiveLimit = 12_000
    private static let contextSnapshotToolLimit = 160

    /// Inspect only the final fitted opening request; keep local snapshots bounded and redacted under the current turn ID.
    /// No bound turn emits nothing. Empty recall without explicit outcome remains unknown, never guessed healthy emptiness.
    @discardableResult
    nonisolated static func fireContextSnapshotEvent(
        surface: String,
        request: ConversationPrefixSeeding.Request,
        messages: [LLMMessage],
        publication: ContextFedRecord.Publication?,
        prefix: ConversationPrefixTelemetrySnapshot?,
        turn: Turn,
        sessionId: String? = nil,
        runId: String? = nil,
        emitReady: Bool = true
    ) -> String? {
        let context = request.seed.context
        let segments = context.systemSegments
        let systemPrompt = request.system ?? request.segments?.combined ?? ""
        let stable = request.segments?.stable ?? ""
        let wireSchemas = request.tools ?? []
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
        let schemaSizes = wireSchemas.map { schema in
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
        let toolSchemaParameterBytes = wireSchemas.reduce(0) {
            $0 + $1.parametersJSON.count
        }
        let toolSchemaMaterialBytes = wireSchemas.reduce(0) {
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
        // Derive active-turn recall outcome from the packet owner, matching preparation traces even when direct recall is empty.
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

        if emitReady { fireContextReady(surface: surface, context: context, sessionId: sessionId, turn: turn) }

        var payload: [String: JSONValue] = [
            "schema": .string("context.snapshot.v1"),
            "model": .string(context.modelId),
            "reasoningEffort": .string(context.reasoningEffort),
            "systemTotalChars": .int(Int64(systemPrompt.count)),
            "stableChars": .int(Int64(stable.count)),
            "dynamicChars": .int(Int64(dynamic.count)),
            "userMessageChars": .int(Int64(context.userMessage.count)),
            "toolSchemaCount": .int(Int64(wireSchemas.count)),
            "toolsAvailableCount": .int(Int64(context.toolsAvailable.count)),
            "recalledCount": .int(Int64(context.recalled.count)),
            "imageBlockCount": .int(Int64(context.imageBlocks.count)),
            "segmented": .bool(request.segments != nil),
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
            // Injected = direct hits ∪ packet provenance (resolvedRecalledIds);
            // `context.recalled` alone is empty on every `.active` turn.
            "memoryRecall": resolvedMemoryRecallOutcome.payload(
                injectedHitCount: context.resolvedRecalledIds.count
            ),
            "promptFingerprintSHA256": .string(promptFingerprint(
                systemPrompt: systemPrompt,
                messages: messages
            )),
            "toolSchemaFingerprintSHA256": .string(toolSchemaFingerprint(wireSchemas)),
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
        payload["wireMessageCount"] = .int(Int64(messages.count))
        payload["snapshotBoundary"] = .string("opening_request")
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
            // Measure UTF-8 bytes beside other byte totals; mixing character counts into a byte denominator would fabricate a percentage.
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
        // Text-tool requests send catalog prose, not schema JSON; measure rows at their actual stable or volatile placement.
        if systemPrompt.contains(AnthropicOAuthTransport.textToolProtocolHeader) {
            do {
                let catalog = try TextMarkerCodec.catalogSections(
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
            } catch {
                payload["toolCatalogMeasurementError"] = .string(String(error.localizedDescription.prefix(1000)))
            }
        }
        if let prefix {
            for (key, value) in prefix.payload { payload[key] = value }
        }
        if let runId, !runId.isEmpty {
            payload["runId"] = .string(runId)
        }
        if let sessionId, !sessionId.isEmpty {
            payload["sessionId"] = .string(sessionId)
        }

        if request.segments != nil {
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
            // Apply the shared recall row bound to trace slices.
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
            payload: .object(payload),
            turn: turn
        )
        if let publication {
            do {
                let saved = try ContextFedRecord.save(publication: publication, surface: surface, fed: dynamic,
                    brief: ridesVolatileBlock ? "" : volatileBlock)
                TurnTraceBus.fireFromContext(kind: "context.fed.saved", sessionId: sessionId, surface: surface,
                    payload: .object(["status": .string(saved ? "saved" : "superseded")]), turn: turn)
            } catch {
                TurnTraceBus.fireFromContext(kind: "context.fed.failed", sessionId: sessionId, surface: surface,
                    payload: .object(["reason": .string(error.localizedDescription)]), turn: turn)
            }
        } else if let sessionId, !sessionId.isEmpty {
            TurnTraceBus.fireFromContext(kind: "context.fed.failed", sessionId: sessionId, surface: surface,
                payload: .object(["reason": .string("No owning data root was supplied for this session's context record.")]), turn: turn)
        }
        return sessionId
    }

    private nonisolated static func promptFingerprint(
        systemPrompt: String,
        messages: [LLMMessage]
    ) -> String {
        var hasher = SHA256()
        updateFingerprint(&hasher, label: "system", data: Data(systemPrompt.utf8))
        for (index, message) in messages.enumerated() {
            let prefix = "message.\(index)"
            updateFingerprint(&hasher, label: prefix + ".role", data: Data(message.role.rawValue.utf8))
            for (blockIndex, block) in message.content.enumerated() {
                updateFingerprint(&hasher, label: prefix + ".block.\(blockIndex)", block: block)
            }
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

/// Retain the latest dynamic context and turn brief in one overwritten session file so the composer can show the actual feed.
/// The trace keeps only its bounded preview.
public enum ContextFedRecord {
    /// Reserved synchronously at dispatch admission, before bookkeeping escapes.
    /// Identity orders publications without assuming task scheduling or wall clocks.
    final class Publication: @unchecked Sendable {
        let sessionId: String
        let dataRoot: URL
        let at = Date()
        var key: String { ContextFedRecord.key(sessionId: sessionId, dataRoot: dataRoot) }
        init(sessionId: String, dataRoot: URL) {
            self.sessionId = sessionId
            self.dataRoot = dataRoot
        }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [String: Publication] = [:]
    /// The writer's actual failure remains visible until a successful write
    /// for this root/session (or process exit); an older file cannot hide it.
    nonisolated(unsafe) private static var writeFailures: [String: String] = [:]

    private static func key(sessionId: String, dataRoot: URL) -> String {
        dataRoot.standardizedFileURL.path + "\u{1F}" + sessionId
    }

    static func begin(sessionId: String, dataRoot: URL) -> Publication {
        let publication = Publication(sessionId: sessionId, dataRoot: dataRoot)
        lock.withLock { pending[publication.key] = publication }
        return publication
    }

    public enum ReadResult: Sendable {
        case missing
        case loaded(Record)
        case unavailable(String)
    }
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

    static func save(publication: Publication, surface: String, fed: String, brief: String) throws -> Bool {
        try lock.withLock {
            guard pending[publication.key] === publication else { return false }
            defer { pending.removeValue(forKey: publication.key) }
            do {
                guard let url = url(sessionId: publication.sessionId, dataRoot: publication.dataRoot) else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                let record = Record(at: publication.at, surface: surface, fed: fed, brief: brief)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(record)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                writeFailures[publication.key] = nil
                return true
            } catch {
                writeFailures[publication.key] = error.localizedDescription
                throw error
            }
        }
    }

    public static func load(sessionId: String, dataRoot: URL) -> ReadResult {
        guard let url = url(sessionId: sessionId, dataRoot: dataRoot) else {
            return .unavailable("Invalid conversation identity; no context file was read.")
        }
        if let failure = lock.withLock({ writeFailures[key(sessionId: sessionId, dataRoot: dataRoot)] }) {
            return .unavailable("The latest context save failed: \(failure). Repair \(url.path); any previous saved record was preserved.")
        }
        do {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .missing }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .loaded(try decoder.decode(Record.self, from: data))
        } catch {
            return .unavailable("\(url.path): \(error.localizedDescription) Repair this saved context record; its bytes have been preserved.")
        }
    }
}
