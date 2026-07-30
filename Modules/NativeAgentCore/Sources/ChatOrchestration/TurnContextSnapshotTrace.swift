import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore

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
    /// swallowed recall failure was a legitimate zero-hit result.
    ///
    /// Production callers invoke this immediately before the initial provider
    /// dispatch. `marksProviderDispatch` can be disabled by inspection-only
    /// callers so `provider.requestStarted` remains an honest boundary.
    nonisolated static func fireContextSnapshotEvent(
        surface: String,
        context: TurnContext,
        sessionId: String? = nil,
        runId: String? = nil,
        systemPromptOverride: String? = nil,
        systemSegmentsOverride: SystemPromptSegments? = nil,
        memoryRecallOutcome: MemoryRecallTraceOutcome? = nil,
        marksProviderDispatch: Bool = true
    ) {
        let segments = systemSegmentsOverride ?? context.systemSegments
        let systemPrompt = systemPromptOverride ?? context.systemPrompt ?? segments?.combined ?? ""
        let stable = segments?.stable ?? ""
        let dynamic = segments?.dynamic ?? ""
        let cognitive = extractCognitiveSubstrate(from: systemPrompt, matchingRunId: runId)
        let resolvedRunId = runId ?? extractRuntimeValue("run_id", from: cognitive ?? systemPrompt)
        let resolvedSessionId = sessionId ?? extractRuntimeValue("session_id", from: cognitive ?? systemPrompt)
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
        let resolvedMemoryRecallOutcome = memoryRecallOutcome
            ?? (context.recalled.isEmpty
                ? .unknown
                : .succeeded(hitCount: context.recalled.count))

        TurnLifecycleTelemetry.emit(
            .contextReady,
            surface: surface,
            sessionId: resolvedSessionId,
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
            "memoryRecall": resolvedMemoryRecallOutcome.payload(
                injectedHitCount: context.recalled.count
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
        if let resolvedRunId, !resolvedRunId.isEmpty {
            payload["runId"] = .string(resolvedRunId)
        }
        if let resolvedSessionId, !resolvedSessionId.isEmpty {
            payload["sessionId"] = .string(resolvedSessionId)
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
            payload["recalled"] = .array(context.recalled.prefix(5).map { hit in
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
            sessionId: resolvedSessionId,
            surface: surface,
            payload: .object(payload)
        )
        if marksProviderDispatch {
            TurnLifecycleTelemetry.emit(
                .providerRequestStarted,
                surface: surface,
                sessionId: resolvedSessionId,
                observedBy: "context.snapshot.return",
                counts: [
                    "systemBytes": Int64(systemBytes),
                    "toolSchemaParameterBytes": Int64(toolSchemaParameterBytes),
                ],
                flags: ["initialRequest": true]
            )
        }
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
            switch block {
            case .image(let mediaType, let base64, let name, let byteSize):
                updateFingerprint(&hasher, label: prefix + ".mediaType", data: Data(mediaType.utf8))
                updateFingerprint(&hasher, label: prefix + ".base64", data: Data(base64.utf8))
                updateFingerprint(&hasher, label: prefix + ".name", data: Data((name ?? "").utf8))
                updateFingerprint(
                    &hasher,
                    label: prefix + ".byteSize",
                    data: Data(String(max(0, byteSize)).utf8)
                )
            case .text(let text):
                updateFingerprint(&hasher, label: prefix + ".text", data: Data(text.utf8))
            case .toolUse(let id, let name, let inputJSON):
                updateFingerprint(&hasher, label: prefix + ".toolUse.id", data: Data(id.utf8))
                updateFingerprint(&hasher, label: prefix + ".toolUse.name", data: Data(name.utf8))
                updateFingerprint(&hasher, label: prefix + ".toolUse.input", data: inputJSON)
            case .toolResult(let toolUseId, let content, let isError):
                updateFingerprint(
                    &hasher,
                    label: prefix + ".toolResult.id",
                    data: Data(toolUseId.utf8)
                )
                updateFingerprint(
                    &hasher,
                    label: prefix + ".toolResult.content",
                    data: Data(content.utf8)
                )
                updateFingerprint(
                    &hasher,
                    label: prefix + ".toolResult.error",
                    data: Data(String(isError).utf8)
                )
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func toolSchemaFingerprint(_ schemas: [LLMToolSchema]) -> String {
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

    private nonisolated static func updateFingerprint(
        _ hasher: inout SHA256,
        label: String,
        data: Data
    ) {
        hasher.update(data: Data("\(label.utf8.count):\(label)\(data.count):".utf8))
        hasher.update(data: data)
    }

    private nonisolated static func extractCognitiveSubstrate(
        from text: String,
        matchingRunId expectedRunId: String? = nil
    ) -> String? {
        let markerText = "[CognitiveSubstrate]"
        let expectedRunId = expectedRunId?.trimmingCharacters(in: .whitespacesAndNewlines)
        var searchRange = text.startIndex..<text.endIndex
        var runtimeMarker: Range<String.Index>?

        while let marker = text.range(of: markerText, range: searchRange) {
            if cognitiveMarkerHasRuntimeHeader(in: text, after: marker.upperBound),
               cognitiveMarkerMatchesExpectedRunId(in: text, after: marker.upperBound, expectedRunId: expectedRunId) {
                runtimeMarker = marker
            }
            searchRange = marker.upperBound..<text.endIndex
        }

        guard let marker = runtimeMarker else { return nil }
        var extracted = String(text[marker.lowerBound...])
        for stop in [
            "\n\nNativeAgent Swift tool protocol",
            "\n\n# Since last session",
        ] {
            if let stopRange = extracted.range(of: stop) {
                extracted = String(extracted[..<stopRange.lowerBound])
            }
        }
        extracted = extracted
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return extracted.isEmpty ? nil : extracted
    }

    private nonisolated static func cognitiveMarkerHasRuntimeHeader(
        in text: String,
        after markerEnd: String.Index
    ) -> Bool {
        let headerEnd = text.index(markerEnd, offsetBy: 500, limitedBy: text.endIndex) ?? text.endIndex
        let header = String(text[markerEnd..<headerEnd])
        return header.contains("\nrun_id:")
            && (header.contains("\nsession_id:") || header.contains("\nsurface:"))
    }

    private nonisolated static func cognitiveMarkerMatchesExpectedRunId(
        in text: String,
        after markerEnd: String.Index,
        expectedRunId: String?
    ) -> Bool {
        guard let expectedRunId, !expectedRunId.isEmpty else { return true }
        let headerEnd = text.index(markerEnd, offsetBy: 500, limitedBy: text.endIndex) ?? text.endIndex
        let header = String(text[markerEnd..<headerEnd])
        return extractRuntimeValue("run_id", from: header) == expectedRunId
    }

    private nonisolated static func extractRuntimeValue(_ key: String, from text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix = key + ":"
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
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
