import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Serialization.swift` | `CognitiveArtifactCodec` validates present fields and nested evidence before restore projections; current episode, proposal, timeline and reflection codecs; `cleanedSessionId` |

/// Validate present evidence before any optional projection can discard it.
/// Missing optional evidence remains unknown; malformed evidence refuses restore.
enum CognitiveArtifactCodec {
    struct FieldFailure: Error, CustomStringConvertible {
        let path: String
        var description: String { "invalid cognitive artifact field: " + path }
    }

    static func validate(_ payload: JSONValue, family: String) throws {
        guard case .object(let object) = payload else { throw FieldFailure(path: family) }
        let required: [String]
        switch family {
        case "capsule_presentation": required = ["updatedAt", "soundRutTurnsSinceSurfaced", "remindedOfTurnsSinceSurfaced", "ambivalenceCount"]
        case "emotional_consolidation": required = ["ranAt", "reinforced", "calmed"]
        case "affect": required = ["updatedAt", "arousal", "uncertainty", "taskPressure", "socialWarmth"]
        case "disposition": required = ["updatedAt", "valence"]
        case "dream_residue": required = ["updatedAt", "claimKeys"]
        case "mind_ledger": required = ["updatedAt", "suppressions", "undo"]
        case "episode": required = ["evidenceNodeIds", "externalEvidenceIds", "lineageId"]
        case "schema_proposal": required = ["confidence", "evidenceNodeIds", "externalEvidenceIds", "lineageId"]
        case "developmental_timeline": required = ["lineageId", "subjectId", "instanceId", "forkMetadata", "externalEvidenceIds"]
        case "reflection_receipt": required = ["requestSourceNodeIds", "requestSourcePeerIds", "requestMaterial", "judgment", "cancelled", "dispositionSaveFailed", "estimatedPromptTokens", "estimatedResultTokens", "estimatedCostUnits", "proposalIds"]
        default: required = []
        }
        for key in required where object[key] == nil { throw FieldFailure(path: family + "." + key + " (missing)") }
        func field(_ key: String, nullable: Bool = false, _ valid: (JSONValue) -> Bool) throws {
            guard let value = object[key] else { return }
            if nullable && value == .null { return }
            guard valid(value) else { throw FieldFailure(path: family + "." + key) }
        }
        func strings(_ key: String, uuids: Bool = false, nullable: Bool = false) throws {
            try field(key, nullable: nullable) { value in
                guard case .array(let rows) = value else { return false }
                return rows.allSatisfy {
                    guard case .string(let text) = $0 else { return false }
                    return !uuids || UUID(uuidString: text) != nil
                }
            }
        }
        func string(_ key: String, nullable: Bool = false, uuid: Bool = false) throws {
            try field(key, nullable: nullable) {
                guard case .string(let text) = $0 else { return false }
                return !uuid || UUID(uuidString: text) != nil
            }
        }
        func number(_ fields: [String: JSONValue], _ key: String, range: ClosedRange<Double>? = nil) -> Bool {
            guard let value = fields[key]?.numberValue(coercingStrings: false, finiteOnly: true) else { return false }
            return range.map { $0.contains(value) } ?? true
        }
        func rows(_ key: String, _ valid: ([String: JSONValue]) -> Bool) throws {
            try field(key) {
                guard case .array(let entries) = $0 else { return false }
                return entries.allSatisfy { row in
                    guard case .object(let fields) = row else { return false }
                    return valid(fields)
                }
            }
        }
        if ["affect", "disposition", "dream_residue", "mind_ledger"].contains(family) {
            try field("updatedAt") { $0.numberValue(coercingStrings: false, finiteOnly: true) != nil }
        }
        switch family {
        case "capsule_presentation":
            for key in ["updatedAt", "lastAmbivalenceAt", "remindedOfLastSurfacedAt", "soundRutLastSurfacedAt", "owedSinceGap", "lastSessionBridgeAt"] {
                try field(key) { $0.numberValue(coercingStrings: false, finiteOnly: true) != nil }
            }
            for key in ["soundRutTurnsSinceSurfaced", "remindedOfTurnsSinceSurfaced", "ambivalenceCount"] {
                try field(key) { if case .int(let count) = $0 { return count >= 0 && Int(exactly: count) != nil }; return false }
            }
            try field("soundRutSignature") { $0.stringValue.map { $0.contains(":") } == true }
            try field("soundRutEarlyRepeatSpent") { if case .bool = $0 { return true }; return false }
            for key in ["remindedOfSurfaced", "dreamThemeSurfaced", "careReleased"] {
                try field(key) {
                    guard case .object(let dates) = $0 else { return false }
                    return dates.allSatisfy { id, date in
                        let validID = key == "careReleased" ? UUID(uuidString: id) != nil
                            : key == "dreamThemeSurfaced" ? id.count <= 48 : id.utf8.count <= 120
                        return validID && date.numberValue(coercingStrings: false, finiteOnly: true) != nil
                    }
                }
            }
            try field("careLineRest") {
                guard case .object(let rests) = $0 else { return false }
                return rests.allSatisfy { id, value in
                    guard UUID(uuidString: id) != nil, case .array(let pair) = value, pair.count == 2,
                          pair[0].numberValue(coercingStrings: false, finiteOnly: true) != nil,
                          case .int(let turns) = pair[1] else { return false }
                    return turns > 0 && turns <= Int64(CognitiveSubstrate.careLineRestTurns)
                }
            }
        case "emotional_consolidation":
            guard number(object, "ranAt") else { throw FieldFailure(path: family + ".ranAt") }
            for key in ["reinforced", "calmed"] {
                try field(key) { if case .int(let count) = $0 { return count >= 0 }; return false }
            }
        case "affect":
            for key in ["arousal", "uncertainty", "taskPressure", "socialWarmth"] {
                guard number(object, key, range: 0...1) else { throw FieldFailure(path: family + "." + key) }
            }
            for key in ["lastUserPresenceAt", "lastWarmPresenceAt"] {
                try field(key) { $0.numberValue(coercingStrings: false, finiteOnly: true) != nil }
            }
            try field("lived") {
                switch $0 {
                case .int(let value): return value >= 0
                case .string(let value): return UInt64(value) != nil
                default: return false
                }
            }
        case "disposition":
            guard number(object, "valence", range: -1...1) else { throw FieldFailure(path: family + ".valence") }
            try strings("dreamNights")
            try field("patternNudgeDays") {
                guard case .object(let claims) = $0 else { return false }
                return claims.values.allSatisfy { if case .string = $0 { return true }; return false }
            }
            try rows("transitions") { row in
                number(row, "at") && number(row, "before", range: -1...1)
                    && number(row, "afterDecay", range: -1...1) && number(row, "afterContribution", range: -1...1)
                    && row["source"]?.stringValue.map { !$0.isEmpty } == true
            }
        case "dream_residue":
            try strings("claimKeys")
            let residueKeys = ["valence", "mintedAt", "turnsRemaining"]
            if residueKeys.contains(where: { object[$0] != nil }) {
                guard number(object, "valence", range: -1...1), number(object, "mintedAt"),
                      case .int(let turns)? = object["turnsRemaining"], turns > 0, Int(exactly: turns) != nil else {
                    throw FieldFailure(path: family + ".residue")
                }
            }
        case "mind_ledger":
            try rows("suppressions") { row in
                guard let source = row["source"]?.stringValue, source.count > 6,
                      ["memory:", "care:", "dream:", "desk:", "ship:"].contains(where: source.hasPrefix),
                      number(row, "at"), case .array(let terms)? = row["terms"] else { return false }
                return terms.allSatisfy { if case .string = $0 { return true }; return false }
            }
            try rows("undo") { row in
                guard row["key"] == .string("disposition"), row["what"]?.stringValue != nil,
                      row["stamp"]?.stringValue != nil, number(row, "at"),
                      case .object(let previous)? = row["previous"] else { return false }
                return number(previous, "valence", range: -1...1) && number(previous, "updatedAt")
            }
            if case .array(let undo)? = object["undo"], undo.count > 1 { throw FieldFailure(path: family + ".undo (multiple)") }
        default: break
        }
        for key in ["evidenceNodeIds", "proposalIds", "requestSourceNodeIds"] { try strings(key, uuids: true) }
        for key in ["externalEvidenceIds"] { try strings(key) }
        try strings("requestSourcePeerIds", nullable: true)
        for key in ["lineageId", "subjectId", "instanceId"] { try string(key) }
        try string("artifactId", nullable: true, uuid: true)
        for key in ["confidence", "occurredAt", "createdAt", "requestedAt", "estimatedCostUnits"] {
            try field(key) { $0.numberValue(coercingStrings: false, finiteOnly: true) != nil }
        }
        for key in ["cancelled", "dispositionSaveFailed", "careIntegrationPending", "journalPending"] {
            try field(key) { if case .bool = $0 { return true }; return false }
        }
        for key in ["estimatedPromptTokens", "estimatedResultTokens"] {
            try field(key) { if case .int(let value) = $0 { return value >= 0 && Int(exactly: value) != nil }; return false }
        }
        try field("forkMetadata") {
            guard case .object(let fields) = $0 else { return false }
            return fields.values.allSatisfy { if case .string = $0 { return true }; return false }
        }
        try field("integrationEpoch") { value in
            guard case .int(let epoch) = value else { return false }
            return epoch >= 0
        }
        try string("integrationSkipped")
        try strings("reflectionClaims", uuids: true)
        if let value = object["requestCares"] {
            do { _ = try JSONDecoder().decode([CognitiveCareLine].self, from: value.serializedData(pretty: false)) }
            catch { throw FieldFailure(path: family + ".requestCares: " + String(describing: error)) }
        } else if object["careIntegrationPending"] == .bool(true) {
            throw FieldFailure(path: family + ".requestCares (missing for owed care integration)")
        }
        if let value = object["requestMaterial"] {
            guard case .object(let causes) = value else { throw FieldFailure(path: family + ".requestMaterial") }
            for (key, cause) in causes {
                do {
                    _ = try JSONDecoder().decode(CognitiveReflectionCause.self, from: cause.serializedData(pretty: false))
                } catch { throw FieldFailure(path: family + ".requestMaterial." + key + ": " + String(describing: error)) }
            }
        }
        if let value = object["judgment"], value != .null {
            do {
                let judgment = try JSONDecoder().decode(CognitiveReflectionJudgment.self, from: value.serializedData(pretty: false))
                guard judgment.affect.map({ $0.isFinite && (-1...1).contains($0) }) ?? true else {
                    throw FieldFailure(path: family + ".judgment.affect")
                }
            } catch { throw FieldFailure(path: family + ".judgment: " + String(describing: error)) }
        }
        if let value = object["careWatchWoke"] {
            guard case .object(let rests) = value else { throw FieldFailure(path: family + ".careWatchWoke") }
            for (key, value) in rests {
                guard key.utf8.count <= 512, UUID(uuidString: String(key.suffix(36))) != nil,
                      case .object(let rest) = value,
                      rest["at"]?.numberValue(coercingStrings: false, finiteOnly: true) != nil,
                      let streak = rest["streak"]?.numberValue(coercingStrings: false, finiteOnly: true),
                      Int(exactly: streak).map({ $0 >= 0 }) == true,
                      rest["lived"]?.stringValue.flatMap({ UInt64($0) }) != nil else {
                    throw FieldFailure(path: family + ".careWatchWoke." + key)
                }
            }
        }
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
        if lived > 0 {
            // JSONValue's integer is signed; keep the full watermark when it
            // does not fit, rather than trapping or lowering the proof.
            object["lived"] = Int64(exactly: lived).map(JSONValue.int) ?? .string(String(lived))
        }
        // These are temporal anchors for the existing analytic quiet-time
        // projection, not a second affect owner. Optional anchors remain absent
        // when no corresponding presence has been observed.
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
        let requestCares: [CognitiveCareLine]
        if let value = object["requestCares"] {
            do { requestCares = try JSONDecoder().decode([CognitiveCareLine].self, from: value.serializedData(pretty: false)) }
            catch { return nil }
        } else {
            guard object["careIntegrationPending"] != .bool(true) else { return nil }
            requestCares = [] // Existing integrated receipts never owed a target lookup.
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
            sourcePeerIds: {
                guard case .array(let rows)? = object["requestSourcePeerIds"],
                      rows.allSatisfy({ if case .string = $0 { return true }; return false }) else { return nil }
                return object["requestSourcePeerIds"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            }(),
            material: {
                guard case .object(let rows)? = object["requestMaterial"] else { return [:] }
                return rows.compactMapValues { value in
                    guard let data = try? value.serializedData(pretty: false) else { return nil }
                    return try? JSONDecoder().decode(CognitiveReflectionCause.self, from: data)
                }
            }(),
            cares: requestCares
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
            affectedCareIDs: object["proposalIds"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? [],
            judgment: {
                guard let value = object["judgment"], value != .null,
                      let data = try? value.serializedData(pretty: false) else { return nil }
                return try? JSONDecoder().decode(CognitiveReflectionJudgment.self, from: data)
            }(),
            dispositionSaveFailed: object["dispositionSaveFailed"]?.boolValue ?? false,
            careIntegrationPending: object["careIntegrationPending"]?.boolValue,
            integrationEpoch: object["integrationEpoch"]?.integerValue.flatMap(UInt64.init(exactly:)),
            integrationSkipped: object["integrationSkipped"]?.stringValue
        )
        journalPending = object["journalPending"]?.boolValue
    }

    func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
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
            "requestSourcePeerIds": request.sourcePeerIds.map { .array($0.map { .string($0) }) } ?? .null,
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
            "proposalIds": .array(affectedCareIDs.map { .string($0.uuidString) }),
        ]
        object["requestCares"] = .array(request.cares.map { .object([
            "key": .string($0.key), "id": .string($0.id.uuidString), "text": .string($0.text)]) })
        if let journalPending { object["journalPending"] = .bool(journalPending) }
        if let careIntegrationPending { object["careIntegrationPending"] = .bool(careIntegrationPending) }
        if let integrationEpoch { object["integrationEpoch"] = .int(Int64(integrationEpoch)) }
        if let integrationSkipped { object["integrationSkipped"] = .string(integrationSkipped) }
        return .object(object)
    }
}
