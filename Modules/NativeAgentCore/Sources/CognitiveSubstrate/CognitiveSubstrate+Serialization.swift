import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Serialization.swift` | `CognitiveSubstrate`: `cleanedSessionId` |

extension CognitiveAffectState {
    func toJSON(
        lastUserPresenceAt: Date? = nil,
        lastWarmPresenceAt: Date? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "arousal": .double(arousal),
            "uncertainty": .double(uncertainty),
            "taskPressure": .double(taskPressure),
            "socialWarmth": .double(socialWarmth),
            "updatedAt": .double(updatedAt.timeIntervalSince1970),
        ]
        if lived > 0 {
            // JSONValue's integer is signed; keep the full watermark when it
            // does not fit, rather than trapping or lowering the proof.
            object["lived"] = Int64(exactly: lived).map(JSONValue.int) ?? .string(String(lived))
        }
        // These are temporal anchors for the existing analytic quiet-time
        // projection, not a second affect owner. Optional fields keep legacy
        // artifacts valid while making fixed-time reads restart-equivalent.
        if let lastUserPresenceAt {
            object["lastUserPresenceAt"] = .double(lastUserPresenceAt.timeIntervalSince1970)
        }
        if let lastWarmPresenceAt {
            object["lastWarmPresenceAt"] = .double(lastWarmPresenceAt.timeIntervalSince1970)
        }
        return .object(object)
    }
}

extension CognitiveEpisodeReference {
    init?(payload: JSONValue) {
        guard let object = payload.objectValue,
              let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let title = object["title"]?.stringValue,
              let summary = object["summary"]?.stringValue,
              let occurredAt = object["occurredAt"]?.numberValue(coercingStrings: false, finiteOnly: false).map(Date.init(timeIntervalSince1970:)) else {
            return nil
        }
        self.init(
            id: id,
            title: title,
            summary: summary,
            occurredAt: occurredAt,
            evidenceNodeIds: object["evidenceNodeIds"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? [],
            externalEvidenceIds: object["externalEvidenceIds"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            lineageId: object["lineageId"]?.stringValue ?? ""
        )
    }

    func toJSON() -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "title": .string(title),
            "summary": .string(summary),
            "occurredAt": .double(occurredAt.timeIntervalSince1970),
            "evidenceNodeIds": .array(evidenceNodeIds.map { .string($0.uuidString) }),
            "externalEvidenceIds": .array(externalEvidenceIds.map { .string($0) }),
            "lineageId": .string(lineageId),
        ])
    }
}

extension CognitiveSchemaProposal {
    init?(payload: JSONValue) {
        guard let object = payload.objectValue,
              let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let title = object["title"]?.stringValue,
              let body = object["body"]?.stringValue,
              let target = object["target"]?.stringValue,
              let createdAt = object["createdAt"]?.numberValue(coercingStrings: false, finiteOnly: false).map(Date.init(timeIntervalSince1970:)) else {
            return nil
        }
        self.init(
            id: id,
            title: title,
            body: body,
            target: target,
            confidence: object["confidence"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0,
            createdAt: createdAt,
            evidenceNodeIds: object["evidenceNodeIds"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? [],
            externalEvidenceIds: object["externalEvidenceIds"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            lineageId: object["lineageId"]?.stringValue ?? ""
        )
    }

    func toJSON() -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "title": .string(title),
            "body": .string(body),
            "target": .string(target),
            "confidence": .double(confidence),
            "createdAt": .double(createdAt.timeIntervalSince1970),
            "evidenceNodeIds": .array(evidenceNodeIds.map { .string($0.uuidString) }),
            "externalEvidenceIds": .array(externalEvidenceIds.map { .string($0) }),
            "lineageId": .string(lineageId),
        ])
    }
}

extension CognitiveDevelopmentalTimelineEvent {
    init?(payload: JSONValue) {
        guard let object = payload.objectValue,
              let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let kindRaw = object["kind"]?.stringValue,
              let kind = CognitiveDevelopmentalTimelineKind(rawValue: kindRaw),
              let title = object["title"]?.stringValue,
              let summary = object["summary"]?.stringValue,
              let occurredAt = object["occurredAt"]?.numberValue(coercingStrings: false, finiteOnly: false).map(Date.init(timeIntervalSince1970:)) else {
            return nil
        }
        self.init(
            id: id,
            kind: kind,
            title: title,
            summary: summary,
            occurredAt: occurredAt,
            artifactId: object["artifactId"]?.stringValue.flatMap(UUID.init(uuidString:)),
            lineageId: object["lineageId"]?.stringValue ?? "",
            subjectId: object["subjectId"]?.stringValue ?? "",
            instanceId: object["instanceId"]?.stringValue ?? "",
            forkMetadata: object["forkMetadata"]?.objectValue?.compactMapValues { $0.stringValue } ?? [:],
            externalEvidenceIds: object["externalEvidenceIds"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        )
    }

    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id.uuidString),
            "kind": .string(kind.rawValue),
            "title": .string(title),
            "summary": .string(summary),
            "occurredAt": .double(occurredAt.timeIntervalSince1970),
            "lineageId": .string(lineageId),
            "subjectId": .string(subjectId),
            "instanceId": .string(instanceId),
            "forkMetadata": .object(forkMetadata.mapValues { .string($0) }),
            "externalEvidenceIds": .array(externalEvidenceIds.map { .string($0) }),
        ]
        if let artifactId {
            obj["artifactId"] = .string(artifactId.uuidString)
        }
        return .object(obj)
    }
}

extension CognitiveSubstrate {
    nonisolated static func cleanedSessionId(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }
}

extension CognitiveEvent {
    var sessionId: String? {
        CognitiveSubstrate.cleanedSessionId(metadata.sessionIdString)
    }
}

extension CognitiveNode {
    var sessionId: String? {
        CognitiveSubstrate.cleanedSessionId(metadata.sessionIdString)
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    var sessionIdString: String? {
        if case .string(let sessionId)? = self["sessionId"] {
            return sessionId
        }
        if case .string(let sessionId)? = self["session_id"] {
            return sessionId
        }
        return nil
    }
}

extension CognitiveReflectionReceipt {
    init?(payload: JSONValue) {
        guard let object = payload.objectValue,
              let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let reason = object["reason"]?.stringValue,
              let prompt = object["prompt"]?.stringValue,
              let surface = object["surface"]?.stringValue,
              let model = object["model"]?.stringValue,
              let requestProvider = object["requestProvider"]?.stringValue,
              let reasoningEffort = object["reasoningEffort"]?.stringValue,
              let requestedAt = object["requestedAt"]?.numberValue(coercingStrings: false, finiteOnly: false).map(Date.init(timeIntervalSince1970:)),
              let resultSummary = object["resultSummary"]?.stringValue,
              let provider = object["provider"]?.stringValue,
              let createdAt = object["createdAt"]?.numberValue(coercingStrings: false, finiteOnly: false).map(Date.init(timeIntervalSince1970:)) else {
            return nil
        }
        let request = CognitiveReflectionRequest(
            reason: reason,
            prompt: prompt,
            surface: surface,
            model: model,
            provider: requestProvider,
            reasoningEffort: reasoningEffort,
            requestedAt: requestedAt,
            // Historical receipts without frozen evidence retain an empty set.
            sourceNodeIds: object["requestSourceNodeIds"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? [],
            materialProvenance: object["requestMaterialProvenance"]?.stringValue
                .flatMap { $0.isEmpty ? nil : $0 },
            sourceExcerpts: object["requestSourceExcerpts"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            sourcePeerIds: {
                guard case .array(let rows)? = object["requestSourcePeerIds"],
                      rows.allSatisfy({ if case .string = $0 { return true }; return false }) else { return nil }
                return object["requestSourcePeerIds"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            }(),
            material: {
                guard case .object(let rows)? = object["requestMaterial"] else { return [:] }
                return rows.compactMapValues { value in
                    if case .string(let text) = value { return CognitiveReflectionCause(text: text) }
                    guard let data = try? value.serializedData(pretty: false) else { return nil }
                    return try? JSONDecoder().decode(CognitiveReflectionCause.self, from: data)
                }
            }()
        )
        self.init(
            id: id,
            request: request,
            resultSummary: resultSummary,
            provider: provider,
            createdAt: createdAt,
            cancelled: object["cancelled"]?.boolValue ?? false,
            estimatedPromptTokens: object["estimatedPromptTokens"]?.integerValue.flatMap(Int.init(exactly:)) ?? 0,
            estimatedResultTokens: object["estimatedResultTokens"]?.integerValue.flatMap(Int.init(exactly:)) ?? 0,
            estimatedCostUnits: object["estimatedCostUnits"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0,
            proposalYieldScore: object["proposalYieldScore"]?.numberValue(coercingStrings: false, finiteOnly: false) ?? 0,
            proposalIds: object["proposalIds"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? [],
            judgment: {
                guard let value = object["judgment"], value != .null,
                      let data = try? value.serializedData(pretty: false) else { return nil }
                return try? JSONDecoder().decode(CognitiveReflectionJudgment.self, from: data)
            }(),
            dispositionSaveFailed: object["dispositionSaveFailed"]?.boolValue ?? false
        )
    }

    func toJSON() -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "reason": .string(request.reason),
            "prompt": .string(request.prompt),
            "surface": .string(request.surface),
            // Checked planning route; these fields do not attest the executed route.
            "model": .string(request.model),
            "requestProvider": .string(request.provider),
            "reasoningEffort": .string(request.reasoningEffort),
            "requestedAt": .double(request.requestedAt.timeIntervalSince1970),
            // Frozen evidence and excerpts retain what formed the care changes.
            "requestSourceNodeIds": .array(request.sourceNodeIds.map { .string($0.uuidString) }),
            "requestSourceExcerpts": .array(request.sourceExcerpts.map { .string($0) }),
            "requestSourcePeerIds": request.sourcePeerIds.map { .array($0.map { .string($0) }) } ?? .null,
            "requestMaterialProvenance": .string(request.materialProvenance ?? ""),
            "requestMaterial": .object(request.material.mapValues { cause in .object([
                "text": .string(cause.text),
                "sourcePeerIds": cause.sourcePeerIds.map { .array($0.map(JSONValue.string)) } ?? .null,
                "sourceNodeIds": .array(cause.sourceNodeIds.map { .string($0.uuidString) }),
                "sourceRefs": .array(cause.sourceRefs.map(JSONValue.string)),
            ]) }),
            "judgment": judgment.map { value in .object([
                "reflection": .string(value.reflection),
                "affect": value.affect.map { .double($0) } ?? .null,
                "takeaway": value.takeaway.map { .string($0) } ?? .null,
                "sources": .array(value.sources.map { .string($0) }),
                "care": value.care.map { .string($0) } ?? .null,
            ]) } ?? .null,
            "resultSummary": .string(resultSummary),
            "provider": .string(provider),
            "createdAt": .double(createdAt.timeIntervalSince1970),
            "cancelled": .bool(cancelled),
            "dispositionSaveFailed": .bool(dispositionSaveFailed),
            "estimatedPromptTokens": .int(Int64(estimatedPromptTokens)),
            "estimatedResultTokens": .int(Int64(estimatedResultTokens)),
            "estimatedCostUnits": .double(estimatedCostUnits),
            "proposalYieldScore": .double(proposalYieldScore),
            "proposalIds": .array(proposalIds.map { .string($0.uuidString) }),
        ])
    }
}
