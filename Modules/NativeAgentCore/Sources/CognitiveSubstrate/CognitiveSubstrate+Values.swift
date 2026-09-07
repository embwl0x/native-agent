import Foundation
import NativeAgentCore
import PersistenceCore

extension CognitiveSubstrate {
    func metadataString(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }


    // Task-tracking is OUT of Agent's cognition — the Desk owns explicit tracking, only when
    // User asks (User, 2026-06-30: "I don't want her subconscious tied up following around me
    // [with] 'I'll'… her subconscious is for her feelings, emotions, her views, her
    // continuity"). The commitment/prediction extractors and their entire downstream —
    // model types, actor state, resolution/lifecycle, capsule cue builders, store paths,
    // Observatory panels — were fully removed on 2026-07-01, and the vestigial assimilate()
    // seam followed on 2026-07-02. Nothing in cognition manufactures commitments/predictions
    // from conversation any longer.

    func isConversationalPresenceStatement(_ lower: String) -> Bool {
        containsAny(lower, [
            "i'll take it",
            "i will take it",
            "i'll be right here",
            "i will be right here",
            "i'll still be here",
            "i will still be here",
            "i'll wait",
            "i will wait",
            "i'll sit right here",
            "i will sit right here",
            "i'll believe it",
            "i will believe it",
            "i won't",
            "i will not",
            "i'll take the bit",
            "i will take the bit",
            "the forgiveness is real",
        ])
    }

    func isOperationalSubconsciousNoise(_ lower: String) -> Bool {
        containsAny(lower, [
            "cognition_microcycle",
            "cognitive_microcycle",
            "context.snapshot",
            "ctx-snapshot",
            "turncontext",
            "rejectmemoryproposal",
            "memoryproposal rejected",
            "ios rejectmemoryproposal",
            "toolobservation",
            "tool observation",
            "bridge-passthrough",
            "provider path is live",
        ])
    }

    func isRuntimeMetaStatement(_ lower: String) -> Bool {
        containsAny(lower, [
            "present-me",
            "reflective-me",
            "capsule",
            "affect line",
            "social warmth",
            "low warmth",
            "working state",
            "private working",
            "runtime hint",
            "runtime state",
            "cognitive substrate",
            "the substrate",
            "reflection pass",
            "reflective pass",
            "subconscious context",
            "provisional runtime",
        ])
    }

    func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    func strippingPrefix(_ prefix: String, from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { return trimmed }
        return String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stableArtifactID(_ key: String) -> UUID {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let suffix = hash % 1_000_000_000_000
        return UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012llu", suffix))") ?? dependencies.makeUUID()
    }

    func stableDigest(_ text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%012llu", hash % 1_000_000_000_000)
    }

    func stringValue(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    func boolValue(_ value: JSONValue?) -> Bool? {
        guard case .bool(let bool)? = value else { return nil }
        return bool
    }

    func intValue(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let int)?:
            return Int(exactly: int)
        case .double(let double)?:
            return Int(exactly: double.rounded(.towardZero))
        default:
            return nil
        }
    }

    func doubleValue(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let double)?:
            return double
        case .int(let int)?:
            return Double(int)
        default:
            return nil
        }
    }

    func dateValue(_ value: JSONValue?) -> Date? {
        guard let seconds = doubleValue(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func uuidValue(_ value: JSONValue?) -> UUID? {
        guard let raw = stringValue(value) else { return nil }
        return UUID(uuidString: raw)
    }

    func uuidArrayValue(_ value: JSONValue?) -> [UUID] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(uuidValue)
    }

    func unique(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        var out: [UUID] = []
        for id in ids where seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }

    func bounded(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters >= 0, text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters))
    }

    func capsuleSignalText(_ text: String, maxCharacters: Int) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let userMessageRange = cleaned.range(of: "User message:", options: [.caseInsensitive, .backwards]) {
            cleaned = String(cleaned[userMessageRange.upperBound...])
        }
        cleaned = cleaned.replacingOccurrences(
            of: "[Telegram voice message]\nTranscript:",
            with: "",
            options: [.caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: "[Telegram voice message] Transcript:",
            with: "",
            options: [.caseInsensitive]
        )
        if let contextStart = cleaned.range(of: "[Telegram reply context]", options: [.caseInsensitive]),
           let contextEnd = cleaned.range(of: "[/Telegram reply context]", options: [.caseInsensitive]),
           contextStart.lowerBound < contextEnd.upperBound {
            cleaned.removeSubrange(contextStart.lowerBound..<contextEnd.upperBound)
        } else if cleaned.range(of: "[Telegram reply context]", options: [.caseInsensitive]) != nil {
            return ""
        }
        cleaned = cleaned.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: [.regularExpression]
        )
        return capsuleLineText(cleaned, maxCharacters: maxCharacters)
    }

    func isUsefulCapsuleSignalText(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("[telegram reply context]")
            || normalized.contains("[/telegram reply context]") {
            return false
        }
        if normalized.hasPrefix("the user replied to telegram message")
            || normalized.hasPrefix("the user replied to a prior message") {
            return false
        }
        return true
    }

    func clamp(_ value: Double) -> Double {
        (value).clamped01()
    }

}
