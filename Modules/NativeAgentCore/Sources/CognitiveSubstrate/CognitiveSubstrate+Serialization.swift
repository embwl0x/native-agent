// CognitiveSubstrate+Serialization.swift
// Move-only extraction (R8b) from CognitiveSubstrate.swift — see docs/build_plans/fable5-wave2-r8b-decomposition.md

import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveMemoryProposalCandidate {
    func toJSON() -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "text": .string(text),
            "source": .string(source),
            "confidence": .double(confidence),
            "kind": .string(kind),
            "evidenceNodeIds": .array(evidenceNodeIds.map { .string($0.uuidString) }),
        ])
    }
}

extension CognitiveMemoryProposalStageReceipt {
    func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "candidateId": .string(candidateId.uuidString),
            "status": .string(status),
        ]
        if let externalProposalId { obj["externalProposalId"] = .string(externalProposalId) }
        if let error { obj["error"] = .string(error) }
        return .object(obj)
    }
}

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

extension CognitiveThoughtSeed {
    func toJSON() -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "kind": .string(kind.rawValue),
            "text": .string(text),
            "priority": .double(priority),
            "createdAt": .double(createdAt.timeIntervalSince1970),
            "lastUpdatedAt": .double(lastUpdatedAt.timeIntervalSince1970),
            "sourceNodeIds": .array(sourceNodeIds.map { .string($0.uuidString) }),
        ])
    }
}

extension CognitiveEpisodeReference {
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
    func toJSON() -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "title": .string(title),
            "body": .string(body),
            "target": .string(target),
            "status": .string(status.rawValue),
            "confidence": .double(confidence),
            "createdAt": .double(createdAt.timeIntervalSince1970),
            "evidenceNodeIds": .array(evidenceNodeIds.map { .string($0.uuidString) }),
            "externalEvidenceIds": .array(externalEvidenceIds.map { .string($0) }),
            "lineageId": .string(lineageId),
        ])
    }
}

extension CognitiveIdentityProposal {
    func toJSON() -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "claim": .string(claim),
            "evidenceCount": .int(Int64(evidenceCount)),
            "status": .string(status.rawValue),
            "createdAt": .double(createdAt.timeIntervalSince1970),
            "evidenceNodeIds": .array(evidenceNodeIds.map { .string($0.uuidString) }),
        ])
    }
}

extension CognitiveDevelopmentalTimelineEvent {
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

extension CognitiveFacultyMeasurement {
    func toJSON() -> JSONValue {
        .object([
            "faculty": .string(faculty),
            "score": .double(score),
            "evidence": .string(evidence),
            "generatedAt": .double(generatedAt.timeIntervalSince1970),
        ])
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

extension CognitiveExperimentResult {
    func toJSON() -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "kind": .string(kind.rawValue),
            "seed": .string(seed),
            "score": .double(score),
            "metrics": .object(metrics.mapValues { .double($0) }),
            "notes": .array(notes.map { .string($0) }),
            "reproducibilityKey": .string(reproducibilityKey),
            "generatedAt": .double(generatedAt.timeIntervalSince1970),
        ])
    }
}

extension CognitiveWelfareBounds {
    func toJSON() -> JSONValue {
        .object([
            "withinBounds": .bool(withinBounds),
            "maxAffectValue": .double(maxAffectValue),
            "reflectionBudgetPressure": .double(reflectionBudgetPressure),
            "notes": .array(notes.map { .string($0) }),
            "generatedAt": .double(generatedAt.timeIntervalSince1970),
        ])
    }
}

extension CognitiveReflectionReceipt {
    func toJSON() -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "reason": .string(request.reason),
            "prompt": .string(request.prompt),
            "surface": .string(request.surface),
            "model": .string(request.model),
            "requestProvider": .string(request.provider),
            "reasoningEffort": .string(request.reasoningEffort),
            "requestedAt": .double(request.requestedAt.timeIntervalSince1970),
            "resultSummary": .string(resultSummary),
            "provider": .string(provider),
            "createdAt": .double(createdAt.timeIntervalSince1970),
            "cancelled": .bool(cancelled),
            "estimatedPromptTokens": .int(Int64(estimatedPromptTokens)),
            "estimatedResultTokens": .int(Int64(estimatedResultTokens)),
            "estimatedCostUnits": .double(estimatedCostUnits),
            "proposalYieldScore": .double(proposalYieldScore),
            "proposalIds": .array(proposalIds.map { .string($0.uuidString) }),
        ])
    }
}
