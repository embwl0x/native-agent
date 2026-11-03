import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Experiences
import CryptoKit
import TurnTrace
import Transcripts
import TrustCenter
import Dispatcher
import MacControl
import MacIntegration
import CognitiveSubstrate
import ChatToolRuntime
import ChatTurnContracts
import ChatToolParsing
import ToolRegistry
// Blueprint: | `ChatOrchestrationClient+InteractionTranscript.swift` | `SwiftNativeChatOrchestrationClient`: tool/approval/card rows, same-row CAS and exact replay witnesses; one locked append reuses open asks by tool and subject within a conversation; shared receipt redaction policy |

extension SwiftNativeChatOrchestrationClient {
    /// Tool results are live-turn data, not durable context. Persist only a
    /// bounded, redacted receipt so tool_catalog/read_file/bash outputs cannot
    /// inflate every future transcript read. The full value remains available
    /// to the provider during the tool loop that produced it.
    private static let persistedToolInputMaximumCharacters = 4_000
    private static let persistedToolResultMaximumCharacters = 8_000

    /// Persist a tool dispatch as the transcript's tool pill.
    func appendToolMessage(
        sessionId: String,
        runId: String?,
        toolName: String,
        invocationID: String,
        input: JSONValue,
        ranCall: (tool: String, input: [String: JSONValue])?,
        result: JSONValue,
        ok: Bool,
        cognitiveResult: ChatToolOutcome.CognitiveResult? = nil,
        source: String = "app"
    ) async throws {
        guard let safeSessionId = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            throw ChatOrchestrationError.underlying("invalid chat session id")
        }
        let messageSource = ChatThreadKind.normalizedSource(source)
        let originalResult = result
        let inputJSON = try input.serialize(pretty: false)
        let safeInputJSON = Self.boundedRedactedToolReceipt(
            try MacInjectionArgRedaction.redactedPayload(tool: toolName, payload: input).serialize(pretty: false),
            maximumCharacters: Self.persistedToolInputMaximumCharacters, label: "tool input")
        let ranTool = ranCall?.tool ?? ToolNameAliases.shown(toolName, input: input).name
        let safeResult = MacInjectionResultRedaction.redacted(tool: ranTool,
            result: MacScreenViewResultRedaction.redacted(tool: ranTool, result: result))
        let safeResultJSON = try safeResult.serialize(pretty: false)
        let safeResultSummary = PersistedToolReceipt.project(tool: ranTool, value: safeResult, json: safeResultJSON,
            maximumCharacters: Self.persistedToolResultMaximumCharacters)
            ?? Self.boundedRedactedToolReceipt(safeResultJSON,
                maximumCharacters: Self.persistedToolResultMaximumCharacters, label: "tool result")
        let canonicalRiskInput: [String: JSONValue] = if case .object(let object) = input { object } else { [:] }
        let canonicalToolRisk = SwiftNativeSecurityCenter.canonicalToolRisk(
            tool: toolName,
            input: canonicalRiskInput,
            dataRoot: dataRoot
        )
        let path = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(safeSessionId).jsonl")
        let messageId = UUID().uuidString
        let persistedAt = clock()
        let createdAt = NativeTimestampFormat.fractionalZulu(persistedAt)
        var record: [String: JSONValue] = [
            "id": .string(messageId),
            "sessionId": .string(sessionId),
            "role": .string("tool"),
            "content": .string(""),
            "createdAt": .string(createdAt),
            "source": .string(messageSource),
        ]
        if let runId { record["runId"] = .string(runId) }
        let pendingApprovalID = ChatTranscriptToolMessageKind.pendingApprovalID(in: originalResult)
        // The approval card's own text lives on the row it is drawn from. Only
        // an approval row gets one; every other tool receipt keeps its empty
        // content exactly as before.
        if pendingApprovalID != nil,
           let asked = ChatTranscriptToolMessageKind.pendingApprovalReason(in: originalResult) {
            record["content"] = .string(asked)
        }
        // Persist card display state on its tool row; native owners retain authority over the underlying need.
        let requestedInteraction = InlineInteractionNeed.interaction(in: originalResult)
        let raisedInteraction = requestedInteraction.map { Self.scrubbedCardDisplay($0) }
        var stampedInteraction: InlineInteraction?
        let origin = TurnEnvelope.current(surface: messageSource)
        var metadata: [String: JSONValue] = [
            "kind": .string(
                raisedInteraction != nil
                    ? InlineInteractionWire.transcriptKind
                    : pendingApprovalID == nil
                        ? ChatTranscriptToolMessageKind.toolUse
                        : ChatTranscriptToolMessageKind.approvalPending
            ),
            "toolName": .string(toolName),
            "toolInvocationId": .string(invocationID),
            "inputJSON": .string(safeInputJSON),
            "resultSummary": .string(safeResultSummary),
            "ok": .bool(ok),
            // Keep the effect’s originating surface and return route on its receipt.
            "envelope": origin.persistedMetadata(),
        ]
        // Keep the small receipt fields before the persisted body is clipped.
        // These are returned values, never the transcript's own id or runId.
        if let ranCall {
            let raw = try JSONValue.object(ranCall.input).serialize(pretty: false)
            let safe = Self.redactedPersistedToolInput(tool: ranCall.tool, json: raw)
            metadata["ranCall"] = .object(["tool": .string(ranCall.tool),
                "input": try JSONValue.parse(Data(safe.utf8))])
        }
        // What its generations made, a list's and a script's included, kept before the body is bounded.
        let generated = ChatGeneratedImageArtifacts.generatedImages(ranTool, ranCall?.input ?? canonicalRiskInput, originalResult)
        if !generated.isEmpty { metadata["generatedImages"] = .array(generated) }
        // What it landed, kept before the body is bounded: a resumed turn still knows her hand.
        if let landed = SwiftNativeTurnEngine.landedEffect(originalResult) { metadata["landedEffect"] = .string(landed) }
        if let id = ChatTranscriptEvidenceRendering.returnedIdentifier(originalResult) {
            metadata["resultReturnedID"] = .string(ChatSecretRedactor.redactText(id))
        }
        if let effects = ChatTranscriptEvidenceRendering.receiptField("effects", in: originalResult) {
            metadata["resultEffects"] = .string(ChatSecretRedactor.redactText(
                String(ChatTranscriptEvidenceRendering.receiptValue(effects).prefix(512))
            ))
        }
        var call = toolName
        if toolName == "app" {
            if case .string(let action)? = canonicalRiskInput["action"] { call += " " + action }
            else if canonicalRiskInput["script"] != nil { call += " script" }
            else if case .array(let list)? = canonicalRiskInput["actions"], !list.isEmpty { call += " actions" }
            else if case .string(let page)? = canonicalRiskInput["page"] { call += " page=" + page }
            else if case .string(let find)? = canonicalRiskInput["find"] { call += " find=" + find }
            else if case .string(let item)? = canonicalRiskInput["item"] { call += " item=" + item }
        }
        var evidence = ChatTranscriptEvidenceRendering.receiptEvidence(call: call, result: safeResult)
        if call == "app script", case .object(var fields) = evidence {
            fields["peer_sources"] = .array((PeerDataTaint.current?.checkpointSources ?? [])
                .map { .string(ChatSecretRedactor.redactText($0)) })
            evidence = .object(ChatTranscriptEvidenceRendering.restoringReceiptBoundaries(fields))
        }
        metadata["receiptEvidence"] = evidence
        if let raisedInteraction {
            metadata["choiceSubject"] = try requestedInteraction.flatMap { try Self.choiceSubject($0) }
            // Runtime-stamped identity locates the exact blocked call; redacted receipt text never becomes replay arguments.
            var stamped = raisedInteraction
            if stamped.continuation == nil {
                // Keep exact blocked-call arguments only when redaction and bounds left them unchanged; otherwise ask the model.
                let exactArguments = safeInputJSON == inputJSON ? inputJSON : nil
                stamped.continuation = try InlineInteraction.Continuation.stamped(
                    for: stamped, sessionID: sessionId, originRunId: runId,
                    toolName: toolName,
                    // app card.request is request_interaction: the card is
                    // the turn's own question, so the turn continues.
                    toolArgumentsJSON: ranTool == InlineInteractionWire.toolName
                        ? nil
                        : exactArguments,
                    mode: ranTool == InlineInteractionWire.toolName
                        ? .continueTurn
                        : .retryBlockedTool,
                    peerSurface: messageSource, originEnvelope: origin, dataRoot: dataRoot
                )
            }
            if let encoded = InlineInteractionNeed.encode(stamped) {
                metadata[InlineInteractionWire.metadataKey] = encoded
            }
            metadata["interactionId"] = .string(stamped.id)
            stampedInteraction = stamped
        }
        if let pendingApprovalID {
            // The post-resolution writer locates and replaces this row by the
            // same durable identifier, so the inline card never loses its
            // transition to a settled tool receipt.
            metadata["approvalId"] = .string(pendingApprovalID)
        }
        // Preserve only the existing classifier's exact outcome tag before
        // receipt clipping/redaction can remove the envelope's status. `ok`
        // remains transport success; no-status legacy results stay unchanged.
        if case .object(let object) = originalResult,
           case .string(let recordedStatus)? = object["status"] {
            metadata["resultClass"] = .string(ChatToolOutcome.exactResultClass(originalResult).rawValue)
            // The class alone cannot tell "queued" from "accepted" from
            // "running" — they all collapse to `.unknown`, which the renderer
            // then reported as "completion unconfirmed" even when the envelope
            // plainly said what state the work reached. Keep the exact word
            // beside the class so the receipt can say what is actually known.
            metadata["resultStatus"] = .string(recordedStatus)
        }
        record["metadata"] = .object(metadata)
        let toolRow: JSONValue = .object(record)
        try await Self.appendTranscriptRow(
            toolRow, to: path)
        if stampedInteraction != nil {
            NotificationCenter.default.post(name: InlineInteractionWire.changedNotification, object: sessionId)
        }
        await observeCognitiveTool(
            sessionId: sessionId,
            runId: runId,
            toolName: ranTool,
            invocationID: invocationID,
            resultSummary: safeResultSummary,
            ok: ok,
            cognitiveResult: cognitiveResult,
            canonicalToolRisk: canonicalToolRisk,
            effects: { if case .string(let value)? = metadata["resultEffects"] { value } else { nil } }(),
            source: messageSource,
            createdAt: createdAt,
            messageId: messageId
        )
    }

    public enum InlineInteractionResolveError: LocalizedError {
        case notFound
        case staleRevision(expected: Int, actual: Int)
        case alreadySettled(String)
        case noControl(String)
        case usersCard

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "That request is no longer in this conversation."
            case .staleRevision(let expected, let actual):
                return "This card moved on (expected \(expected), found \(actual)). Reopen it."
            case .alreadySettled(let state):
                return "That was already \(state)."
            case .usersCard:
                return "That card is in the owner's conversation waiting for them, so answering it is theirs. "
                    + "Nothing was changed; Not now still withdraws your ask."
            case .noControl(let detail):
                return detail
            }
        }
    }

    package static func checkedInlineInteraction(in row: JSONValue, lifeID: String? = nil) throws -> InlineInteraction? {
        guard case .object(let object) = row,
              case .object(let metadata)? = object["metadata"],
              case .string(InlineInteractionWire.transcriptKind)? = metadata["kind"]
        else { return nil }
        guard let raw = metadata[InlineInteractionWire.metadataKey] else {
            throw InlineInteractionResolveError.noControl("The saved interaction card has no interaction payload. Repair its transcript row.")
        }
        var card = try InlineInteractionWire.decoder().decode(InlineInteraction.self,
            from: raw.serializedData(pretty: false))
        if let lifeID, let continuation = card.continuation,
           DataRootLife.life(of: continuation.lifeID) != lifeID,
           [.waiting, .claimed, .replaying, .stopped].contains(continuation.state) {
            card.continuation?.state = .stopped
            card.continuation?.reason = DataRootLife.stoppedReason
            card.state = .stopped(reason: DataRootLife.stoppedReason)
        }
        return card
    }

    /// The same-row card CAS: compare the persisted revision and continuation
    /// under the transcript lock, preserving the row's identity and provenance.
    package static func persistInlineInteraction(
        _ interaction: InlineInteraction, at file: URL,
        ifRevision expected: Int? = nil, expecting: (@Sendable (InlineInteraction) -> Bool)? = nil
    ) async throws {
        let lifeID = try DataRootLife.current(in: file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        try await SwiftNativePersistenceCore.withFileLock(file) {
            let read = try await SwiftNativePersistenceCore.readJSONLReporting(file)
            guard read.report.isClean else {
                throw PersistenceCoreError.ioFailure(
                    "This conversation has damaged rows. Nothing was changed."
                )
            }
            var rows = read.rows
            guard let index = rows.firstIndex(where: {
                guard case .object(let row) = $0,
                      case .object(let metadata)? = row["metadata"],
                      metadata["kind"] == .string(InlineInteractionWire.transcriptKind),
                      case .object(let raw)? = metadata[InlineInteractionWire.metadataKey] else { return false }
                return raw["id"] == .string(interaction.id)
            }) else { throw InlineInteractionResolveError.notFound }
            guard let persisted = try checkedInlineInteraction(in: rows[index], lifeID: lifeID) else {
                throw InlineInteractionResolveError.notFound
            }
            if let expected {
                guard persisted.revision == expected else {
                    throw InlineInteractionResolveError.staleRevision(
                        expected: expected, actual: persisted.revision
                    )
                }
            }
            if let expecting {
                guard expecting(persisted) else {
                    throw InlineInteractionResolveError.staleRevision(
                        expected: interaction.revision, actual: persisted.revision
                    )
                }
            }
            guard case .object(var object) = rows[index],
                  case .object(var metadata)? = object["metadata"]
            else { throw InlineInteractionResolveError.notFound }
            if let encoded = InlineInteractionNeed.encode(interaction) {
                metadata[InlineInteractionWire.metadataKey] = encoded
            }
            let envelope = inlineInteractionReceiptEnvelope(interaction)
            metadata["resultSummary"] = .string(
                try envelope.serialize(pretty: false)
            )
            metadata["resultStatus"] = .string(interaction.state.name)
            metadata["resultClass"] = .string(
                ChatToolOutcome.exactResultClass(envelope).rawValue
            )
            if let summary = interaction.state.outcome?.summary, !summary.isEmpty {
                metadata["resultBody"] = .string(summary)
            }
            metadata["ok"] = .bool(interaction.state.outcome != nil)
            object["metadata"] = .object(metadata)
            rows[index] = .object(object)
            try ContactThread.replace(rows, to: file)
        }
    }

    package static func inlineInteractionReceiptEnvelope(_ interaction: InlineInteraction) -> JSONValue {
        switch interaction.state {
        case .stopped(let reason):
            return .object(["status": .string("stopped"), "reason": .string(reason)])
        case .settled(let outcome):
            return .object([
                "status": .string("succeeded"),
                "ok": .bool(true),
                "detail": .string(outcome.summary),
            ])
        case .declined:
            return .object([
                "status": .string("cancelled"),
                "detail": .string(interaction.declineConsequence),
            ])
        // Replaced asks carry the same cancelled outcome as a declined card.
        case .superseded:
            return .object([
                "status": .string("cancelled"),
                "detail": .string("A newer identical request replaced this one."),
            ])
        case .failed(let reason):
            return .object([
                "status": .string("failed"),
                "ok": .bool(false),
                "error": .string(reason),
            ])
        default:
            return .object([
                "status": .string(InlineInteractionWire.waitingStatus),
                "detail": .string(interaction.why),
            ])
        }
    }

    /// One open ask per conversation, originating tool and subject. The
    /// duplicate check and append share the transcript lock, so simultaneous
    /// re-asks return the same card without a second mirror or prompt.
    /// Transcript JSONL is locally backed up, excluded from production export,
    /// projected to the phone and listed by PrivacyMap's chat category.
    package static func fileInlineInteraction(
        _ interaction: InlineInteraction, sessionID: String, resumeText: String? = nil,
        resumable: Bool = true, toolName: String? = nil, toolArgumentsJSON: String? = nil,
        toolCallId: String? = nil, requestingTool: String? = nil,
        origin: TurnEnvelope, dataRoot: URL
    ) async throws -> InlineInteraction {
        guard let safeSession = NativeAgentChatSessionID.normalizedPathComponent(sessionID) else {
            throw ChatOrchestrationError.underlying("invalid chat session id")
        }
        var stamped = scrubbedCardDisplay(interaction)
        if stamped.continuation == nil {
            stamped.continuation = try InlineInteraction.Continuation.stamped(
                for: stamped, sessionID: sessionID, originRunId: ChatTurnExecution.current?.historyRunID, toolCallId: toolCallId,
                toolName: toolName, toolArgumentsJSON: toolArgumentsJSON,
                mode: toolName == nil ? .continueTurn : .retryBlockedTool,
                state: resumable ? .waiting : .invalidated, resumeText: resumeText,
                peerSurface: origin.surface, originEnvelope: origin, dataRoot: dataRoot)
        }
        guard let encoded = InlineInteractionNeed.encode(stamped) else {
            throw ChatOrchestrationError.underlying("The interaction card could not be encoded; no card was filed.")
        }
        let envelope = inlineInteractionReceiptEnvelope(stamped)
        var metadata: [String: JSONValue] = [
            "kind": .string(InlineInteractionWire.transcriptKind),
            "toolName": .string(requestingTool ?? toolName ?? InlineInteractionWire.toolName),
            "inputJSON": .string("{}"), "resultSummary": .string(try envelope.serialize(pretty: false)),
            "resultStatus": .string(stamped.state.name), "ok": .bool(false),
            InlineInteractionWire.metadataKey: encoded, "interactionId": .string(stamped.id),
            "envelope": origin.persistedMetadata(),
        ]
        metadata["choiceSubject"] = try choiceSubject(interaction)
        let row: JSONValue = .object([
            "id": .string(UUID().uuidString.lowercased()), "sessionId": .string(sessionID),
            "role": .string("tool"), "content": .string(""),
            "createdAt": .string(ISO8601DateFormatter().string(from: Date())),
            "source": .string(origin.surface), "runId": .string(stamped.continuation?.resumeRunId ?? stamped.id),
            "metadata": .object(metadata),
        ])
        let path = dataRoot.appendingPathComponent("chat/messages/\(safeSession).jsonl")
        guard let retained = try await appendTranscriptRow(row, to: path) else {
            throw ChatOrchestrationError.underlying("The interaction append returned no card.")
        }
        return retained
    }

    @discardableResult
    package static func appendTranscriptRow(_ row: JSONValue, to path: URL) async throws -> InlineInteraction? {
        let lifeID: String?
        if row.objectValue?["metadata"]?.objectValue?["kind"] == .string(InlineInteractionWire.transcriptKind) {
            lifeID = try DataRootLife.current(in: path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        } else { lifeID = nil }
        return try await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> InlineInteraction? in
            let incoming = try checkedInlineInteraction(in: row, lifeID: lifeID)
            if let incoming {
                let read = try await SwiftNativePersistenceCore.readJSONLReporting(path)
                guard read.report.isClean else {
                    throw PersistenceCoreError.ioFailure("This conversation has damaged rows. No new card was filed.")
                }
                func tool(_ card: InlineInteraction, _ row: JSONValue) -> String? {
                    card.continuation?.toolName ?? row.objectValue?["metadata"]?.objectValue?["toolName"]?.stringValue
                }
                func retainReceipt(pointingTo card: InlineInteraction) async throws {
                    guard case .object(var receipt) = row,
                          case .object(var metadata)? = receipt["metadata"],
                          metadata["toolInvocationId"] != nil else { return }
                    // Keep the dispatch receipt without minting another card.
                    metadata["kind"] = .string(ChatTranscriptToolMessageKind.toolUse)
                    metadata.removeValue(forKey: InlineInteractionWire.metadataKey)
                    metadata["interactionId"] = .string(card.id)
                    receipt["metadata"] = .object(metadata)
                    try await ContactThread.append(.object(receipt), to: path)
                }
                for (index, prior) in read.rows.enumerated().reversed() {
                    let card: InlineInteraction
                    do {
                        guard let decoded = try checkedInlineInteraction(in: prior, lifeID: lifeID) else { continue }
                        card = decoded
                    } catch {
                        // An unreadable card cannot establish ask identity. Keep its
                        // bytes and one row-owned repair while matching its siblings.
                        let rowID = prior.objectValue?["id"]?.stringValue ?? "row-\(index + 1)"
                        let operation = "interaction-row:" + path.path + ":" + rowID
                        let dataRoot = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                        RepairOwed.owe(dataRoot, id: operation, kind: .run,
                            operation: operation, owner: path.path + " row " + rowID,
                            words: "Saved interaction row \(rowID) is unreadable and was skipped when matching asks: \(error.localizedDescription)",
                            tap: ToolFailureError.fileRepairInstruction(path,
                                shape: "Repair only interaction row \(rowID)'s payload to the current InlineInteraction contract, retaining its actual identity and continuation."))
                        continue
                    }
                    if card.id == incoming.id {
                        try await retainReceipt(pointingTo: card)
                        return card
                    }
                    if card.state.isOpen,
                       tool(card, prior) == tool(incoming, row),
                       card.kind == incoming.kind,
                       card.allTargets.sorted() == incoming.allTargets.sorted(),
                       card.mode == incoming.mode, card.secret == incoming.secret,
                       (card.kind != .choose || (row.objectValue?["metadata"]?.objectValue?["choiceSubject"] != nil
                        && prior.objectValue?["metadata"]?.objectValue?["choiceSubject"] == row.objectValue?["metadata"]?.objectValue?["choiceSubject"])),
                       card.options.sorted(by: { $0.id < $1.id }) == incoming.options.sorted(by: { $0.id < $1.id }) {
                        try await retainReceipt(pointingTo: card)
                        return card
                    }
                }
            }
            try await ContactThread.append(row, to: path)
            return incoming
        }
    }

    /// Match the whole authored question and options, before display redaction
    /// and clipping can make different subjects look alike. Only its digest is saved.
    private static func choiceSubject(_ card: InlineInteraction) throws -> JSONValue? {
        guard card.kind == .choose else { return nil }
        struct Subject: Encodable {
            let question: String
            let options: [InlineInteraction.Option]
        }
        let encoder = InlineInteractionWire.encoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Subject(question: card.title,
            options: card.options.sorted { $0.id < $1.id }))
        return .string(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    nonisolated static func redactedProgressEvent(_ event: TurnStreamEvent) -> TurnStreamEvent {
        switch event {
        case .toolUse(let name, let input):
            return .toolUse(name: name, input: ChatSecretRedactor.redactValue(input))
        case .toolResult(let name, let output):
            return .toolResult(name: name, output: ChatSecretRedactor.redactValue(output))
        case .error(let message):
            return .error(ChatSecretRedactor.redactText(message))
        default:
            return event
        }
    }

    /// Transcripts and card continuations strip tool injection/screenshots, then redact secrets and bound receipts.
    public nonisolated static func redactedPersistedToolResult(
        tool: String, json: String
    ) -> String {
        let safeResult = ChatToolJSONRedaction.redactedResultJSON(tool: tool, json: json)
        if let value = try? JSONValue.parse(Data(safeResult.utf8)),
           let receipt = PersistedToolReceipt.project(
            tool: tool, value: value, json: safeResult, maximumCharacters: persistedToolResultMaximumCharacters
        ) { return receipt }
        return boundedRedactedToolReceipt(
            safeResult,
            maximumCharacters: persistedToolResultMaximumCharacters,
            label: "tool result"
        )
    }

    /// The same for a tool's ARGUMENTS: typed secrets by tool, then the
    /// secret redactor and the input cap. Also what a Desk checkpoint keeps.
    public nonisolated static func redactedPersistedToolInput(tool: String, json: String) -> String {
        boundedRedactedToolReceipt(
            ChatToolJSONRedaction.injectionRedactedArgJSON(tool: tool, json: json),
            maximumCharacters: persistedToolInputMaximumCharacters,
            label: "tool input"
        )
    }

    /// Treat all card display text as tool output: scrub and bound it before persistence and signature witnessing.
    package static func scrubbedCardDisplay(_ interaction: InlineInteraction) -> InlineInteraction {
        var copy = interaction
        copy.title = Self.scrubbedCardText(copy.title, maximumCharacters: 120)
        copy.why = Self.scrubbedCardText(copy.why, maximumCharacters: 400)
        copy.primaryActionLabel = Self.scrubbedCardText(
            copy.primaryActionLabel, maximumCharacters: 80)
        copy.secondaryActionLabel = copy.secondaryActionLabel.map {
            Self.scrubbedCardText($0, maximumCharacters: 80)
        }
        copy.declineConsequence = Self.scrubbedCardText(
            copy.declineConsequence, maximumCharacters: 400)
        copy.persistenceNote = copy.persistenceNote.map {
            Self.scrubbedCardText($0, maximumCharacters: 240)
        }
        copy.cardProse = copy.cardProse.map { Self.scrubbedCardText($0, maximumCharacters: 400) }
        copy.options = copy.options.map { option in
            var option = option
            option.label = Self.scrubbedCardText(option.label, maximumCharacters: 120)
            option.detail = option.detail.map {
                Self.scrubbedCardText($0, maximumCharacters: 240)
            }
            return option
        }
        if case .settled(var outcome) = copy.state {
            outcome.summary = Self.scrubbedCardText(outcome.summary, maximumCharacters: 240)
            copy.state = .settled(outcome)
        }
        if case .failed(let reason) = copy.state {
            copy.state = .failed(
                reason: Self.scrubbedCardText(reason, maximumCharacters: 240))
        }
        return copy
    }

    private nonisolated static func scrubbedCardText(
        _ value: String, maximumCharacters: Int
    ) -> String {
        // Redact a guard window past the cap, exactly as the receipt bound
        // does, so a secret starting near the boundary cannot be cut into an
        // unrecognized fragment and kept.
        let window = String(value.prefix(maximumCharacters + 512))
        // Display redaction preserves ordinary labels and replaces values only when they prove to be secrets.
        return String(TurnSecretRedactor.redactDisplayText(window).prefix(maximumCharacters))
    }

    private nonisolated static func boundedRedactedToolReceipt(
        _ value: String,
        maximumCharacters: Int,
        label: String
    ) -> String {
        guard maximumCharacters > 0 else { return "" }
        let sourceCount = value.count
        guard sourceCount > maximumCharacters else {
            return ChatSecretRedactor.redactText(value)
        }
        // Redact a small guard window beyond the persisted boundary so a
        // secret beginning near the cutoff cannot be split into an unrecognized
        // fragment. Work remains O(the receipt cap), not O(tool output size).
        let redactionWindow = String(value.prefix(maximumCharacters + 512))
        let redacted = ChatSecretRedactor.redactText(redactionWindow)
        let omitted = sourceCount - maximumCharacters
        return String(redacted.prefix(maximumCharacters))
            + "\n[... \(label) truncated in transcript; \(omitted) characters omitted ...]"
    }

}
