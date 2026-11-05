import Foundation
import CryptoKit
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TurnTrace
import TrustCenter
import MacControl
import MacIntegration
import CognitiveSubstrate
import ChatToolRuntime
import ChatToolParsing
import ToolRegistry
// Blueprint: | `ChatOrchestrationClient+LivedObservations.swift` | `SwiftNativeChatOrchestrationClient`; Explicit provenance and bounded cognitive events |

extension SwiftNativeChatOrchestrationClient {
    static func afterTurnOrigin(in rows: [JSONValue], sessionId: String, runId: String) throws -> AfterTurnOrigin? {
        let matches = rows.compactMap { value -> AfterTurnOrigin? in
            guard case .object(let row) = value,
                  row["role"] == .string("user"), row["runId"] == .string(runId),
                  case .string(let id)? = row["id"], !id.isEmpty,
                  case .string(let content)? = row["content"] else { return nil }
            let at: Date?
            if case .string(let timestamp)? = row["createdAt"] {
                at = NativeTimestampFormat.parseISO8601FractionalFirst(timestamp)
            } else { at = nil }
            return AfterTurnOrigin(sessionId: sessionId, runId: runId,
                messageId: id, occurredAt: at, userMessage: content)
        }
        guard matches.count <= 1 else {
            throw ChatOrchestrationError.underlying("incoming turn identity is ambiguous")
        }
        return matches.first
    }

    func observeCognitiveMessage(
        sessionId: String,
        role: String,
        content: String,
        runId: String?,
        source: String,
        createdAt: String,
        messageId: String,
        origin: ChatMessageOrigin? = nil,
        recalledMemoryIds: [String] = [],
        mechanicalRow: CognitiveMechanicalRowKind? = nil
    ) async {
        guard let cognitiveRuntime else { return }
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kind: CognitiveEventKind
        let sourceClass: CognitiveSourceClass
        let importance: Double
        switch normalizedRole {
        case "user":
            kind = .userMessageReceived
            // Out-of-band origin decides trust class; a bridge worker's typed prefix cannot establish human authorship.
            sourceClass = origin == nil ? .userStated : .imported
            importance = 0.65
        case "assistant":
            // Only the writer's .systemRow stamp classifies an assistant row as a provider failure.
            if mechanicalRow == .systemRow {
                kind = .providerFailure
                sourceClass = .observed
                importance = 0.85
            } else {
                kind = .assistantTurnCompleted
                sourceClass = .selfReported
                importance = 0.55
            }
        default:
            return
        }
        let redactedSummary = ChatSecretRedactor.redactText(content)
        var metadata: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "messageId": .string(messageId),
            "role": .string(normalizedRole),
            "source": .string(source),
        ]
        if normalizedRole == "user", let origin {
            // Keep bounded transcript correlation in the cognitive ledger; route provenance is not process identity attestation.
            var cognitiveOrigin: [String: JSONValue] = [
                "surface": .string(String(origin.surface.unicodeScalars.prefix(80))),
            ]
            if let agent = origin.agent {
                let boundedAgent = String(agent.unicodeScalars.prefix(80))
                if !boundedAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cognitiveOrigin["agent"] = .string(boundedAgent)
                }
            }
            // Forward only explicit authorship; route provenance alone cannot distinguish agent speech from relayed human words.
            if let authored = origin.authored {
                cognitiveOrigin["authored"] = .string(authored.rawValue)
            }
            metadata["origin"] = .object(cognitiveOrigin)
        }
        if let runId { metadata["runId"] = .string(runId) }
        if kind == .providerFailure, providerLifecycleObserverInstalled {
            metadata[CognitiveSomaticSignals.somaticOwnerMetadataKey] = .string(
                CognitiveSomaticSignals.providerLifecycleSomaticOwner
            )
        }
        // Completed assistant events carry deduplicated, bounded recalled IDs for the substrate's felt-memory activation.
        if normalizedRole == "assistant", kind == .assistantTurnCompleted, !recalledMemoryIds.isEmpty {
            let bounded = Array(Set(recalledMemoryIds)).sorted().prefix(32)
            metadata["memoryRecordIds"] = .array(bounded.map { .string($0) })
        }
        if normalizedRole == "assistant", kind == .assistantTurnCompleted {
            // Sound needs the full redacted reply length to distinguish a
            // complete summary from a clipped head. Carry only the count.
            metadata[CognitiveSubstrate.replyCharacterCountMetadataKey] =
                .int(Int64(redactedSummary.count))
            // The summary keeps the head; a long reply's sign-off is where a
            // form of address lives, so the Sound rut detector gets the tail.
            if redactedSummary.count > 500 {
                metadata[CognitiveSubstrate.replyTailMetadataKey] =
                    .string(String(redactedSummary.suffix(300)))
            }
        }
        // Keep writer provenance on the node so readers need not infer it from prose.
        if let mechanicalRow {
            metadata[CognitiveMechanicalRowKind.metadataKey] = .string(mechanicalRow.rawValue)
        }
        let turnKind = Self.cognitiveMessageTurnKind(
            mechanicalRow: mechanicalRow
        )
        let subject: CognitiveSubjectReference
        if normalizedRole == "assistant", kind == .assistantTurnCompleted {
            subject = CognitiveSubjectReference(
                type: "chat.assistant_turn",
                id: "\(sessionId):\(messageId)",
                // The substrate derives a safe topic from the redacted summary, or leaves it absent.
                label: CognitiveSubstrate.feltTopicLabel(from: redactedSummary)
            )
        } else if kind == .userMessageReceived || kind == .userCorrection {
            // User and assistant subjects identify individual turns; session continuity uses sessionId metadata.
            subject = CognitiveSubjectReference(
                type: "chat.user_turn",
                id: "\(sessionId):\(messageId)",
                // The substrate derives a safe topic from the redacted summary, or leaves it absent.
                label: CognitiveSubstrate.feltTopicLabel(from: redactedSummary)
            )
        } else {
            subject = CognitiveSubjectReference(type: "chat.session", id: sessionId)
        }
        await cognitiveRuntime.observe(CognitiveEvent(
            id: "chat:\(sessionId):\(messageId)",
            kind: kind,
            subject: subject,
            sourceClass: sourceClass,
            occurredAt: NativeTimestampFormat.parseISO8601FractionalFirst(createdAt) ?? clock(),
            summary: String(redactedSummary.prefix(500)),
            importance: importance,
            turnKind: turnKind,
            metadata: metadata
        ))
    }

    /// One workload-class boundary for accepted events and their capsules.
    /// Capsule preparation must not reinterpret admitted live prose as debug.
    nonisolated static func cognitiveMessageTurnKind(
        mechanicalRow: CognitiveMechanicalRowKind? = nil
    ) -> CognitiveTurnKind {
        // The writer's provenance excludes mechanical rows from lived state.
        // Unmarked prose is live; its text cannot declare diagnostic provenance.
        mechanicalRow == nil ? .live : .mechanical
    }

    func observeCognitiveTool(
        sessionId: String,
        runId: String?,
        toolName: String,
        invocationID: String,
        resultSummary: String,
        ok: Bool,
        cognitiveResult: ChatToolOutcome.CognitiveResult?,
        canonicalToolRisk: CanonicalToolRisk,
        effects: String? = nil,
        source: String,
        createdAt: String,
        messageId: String
    ) async {
        guard let cognitiveRuntime else { return }
        let exactCognitiveResult = cognitiveResult ?? (ok ? .succeeded : .failed)
        guard exactCognitiveResult != .unknown else { return }
        var metadata: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "messageId": .string(messageId),
            "toolName": .string(toolName),
            "toolInvocationId": .string(invocationID),
            "ok": .bool(ok),
            "source": .string(source),
            "trustRisk": .string(canonicalToolRisk.rawValue),
        ]
        if let runId { metadata["runId"] = .string(runId) }
        // The receipt owns the evidence of whether the tool took effect.
        if let effects { metadata["effects"] = .string(effects) }
        let succeeded = exactCognitiveResult == .succeeded
        let status = succeeded ? "ok" : "failed"
        let summary = resultSummary.isEmpty
            ? "\(toolName) \(status)"
            : "\(toolName) \(status): \(resultSummary)"
        await cognitiveRuntime.observe(CognitiveEvent(
            id: "chat-tool:\(sessionId):\(messageId)",
            kind: succeeded ? .toolSucceeded : .toolFailed,
            subject: CognitiveSubjectReference(type: "tool", id: toolName, label: toolName),
            sourceClass: .observed,
            occurredAt: NativeTimestampFormat.parseISO8601FractionalFirst(createdAt) ?? clock(),
            summary: String(summary.prefix(500)),
            importance: succeeded ? 0.55 : 0.8,
            metadata: metadata
        ))
    }

    func observeCognitiveProgressEvent(
        sessionId: String,
        runId: String?,
        surface: String,
        event: TurnStreamEvent,
        turn: Turn
    ) async {
        guard let cognitiveRuntime else { return }
        let occurredAt = clock()
        switch event {
        case .toolUse(let name, let input):
            let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeName.isEmpty else { return }
            // Motor owners emit exact lifecycle identities. Generic starts here cannot pair with their terminals and would leave false pending state.
            let ranInput: [String: JSONValue] = if case .object(let fields) = input { fields } else { [:] }
            let ranTool = ToolNameAliases.ranTool(safeName, input: ranInput)
            guard !ChatToolOutcome.hasCanonicalMotorOwner(ranTool),
                  let invocationID = turn.invocationID else { return }
            // Persisted physiology uses by-tool redaction before cutting its preview.
            let inputPreview = Self.compactCognitiveJSON(
                MacInjectionArgRedaction.redactedPayload(tool: safeName, payload: input, turn: turn),
                maxCharacters: 240
            )
            var metadata: [String: JSONValue] = [
                "sessionId": .string(sessionId),
                "toolName": .string(ranTool),
                "toolInvocationId": .string(invocationID),
                "surface": .string(surface),
                "phase": .string("started"),
                "inputPreview": .string(inputPreview),
            ]
            if let runId { metadata["runId"] = .string(runId) }
            await cognitiveRuntime.observe(CognitiveEvent(
                id: "chat-tool-start:\(invocationID)",
                kind: .toolStarted,
                subject: CognitiveSubjectReference(type: "tool", id: ranTool, label: ranTool),
                sourceClass: .observed,
                occurredAt: occurredAt,
                summary: inputPreview.isEmpty
                    ? "\(safeName) started"
                    : "\(safeName) started: \(inputPreview)",
                importance: 0.45,
                metadata: metadata
            ))

        case .error(let message):
            // The lifecycle observer owns provider physiology when installed; otherwise progress errors supply it.
            guard !providerLifecycleObserverInstalled else { return }
            let safe = ChatSecretRedactor.redactText(message)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safe.isEmpty else { return }
            var metadata: [String: JSONValue] = [
                "sessionId": .string(sessionId),
                "surface": .string(surface),
                "phase": .string("progress_error"),
            ]
            if let runId { metadata["runId"] = .string(runId) }
            await cognitiveRuntime.observe(CognitiveEvent(
                id: "chat-provider-progress-error:\(sessionId):\(runId ?? "no-run"):\(Self.cognitiveDigest(safe))",
                kind: .providerFailure,
                subject: CognitiveSubjectReference(type: "chat.surface", id: surface, label: surface),
                sourceClass: .observed,
                occurredAt: occurredAt,
                summary: String(safe.prefix(500)),
                importance: 0.85,
                metadata: metadata
            ))

        case .toolResult, .delta, .final, .notice, .replyTextSettled, .writing:
            return
        }
    }

    nonisolated private static func compactCognitiveJSON(_ value: JSONValue, maxCharacters: Int) -> String {
        do { return String(try value.serialize(pretty: false).prefix(max(0, maxCharacters))) }
        catch { return "[Observation unavailable: JSON encoding failed (\(error.localizedDescription)). Repair its producing owner.]" }
    }

    nonisolated private static func cognitiveDigest(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

}
