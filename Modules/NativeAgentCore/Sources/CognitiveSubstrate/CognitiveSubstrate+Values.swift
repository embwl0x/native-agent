import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `CognitiveSubstrate+Values.swift` | `CognitiveSubstrate`: `metadataString`, `isConversationalPresenceStatement`, `isOperationalSubconsciousNoise` |

extension CognitiveSubstrate {
    func metadataString(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }


    // The Desk owns task tracking when User asks; cognition does not extract commitments from conversation.

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
            // The microcycle's own pressure seed (+Workspace.swift). It is a
            // runtime reading of uncertainty/task-pressure, not something she
            // noticed — and because the text is byte-identical every cycle it
            // held ~19 of 26 seed slots on the live install. Operational: never
            // leads a capsule line or a shoulder tap.
            "re-check high-pressure cognitive state",
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

    /// Pure substring matching lets studio valence and relational warmth read
    /// text without entering the actor.
    nonisolated func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    func strippingPrefix(_ prefix: String, from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { return trimmed }
        return String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stableArtifactID(_ key: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(stableDigest(key))") ?? dependencies.makeUUID()
    }

    func stableDigest(_ text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%012llu", hash % 1_000_000_000_000)
    }

    func dateValue(_ value: JSONValue?) -> Date? {
        guard let seconds = value?.numberValue(coercingStrings: false, finiteOnly: false) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func uuidValue(_ value: JSONValue?) -> UUID? {
        guard let raw = value?.stringValue else { return nil }
        return UUID(uuidString: raw)
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

}
