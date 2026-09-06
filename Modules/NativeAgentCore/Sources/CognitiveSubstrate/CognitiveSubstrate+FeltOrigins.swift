// CognitiveSubstrate+FeltOrigins.swift
// The PROVENANCE half of the felt day — subject + metadata of the last-24h felt
// nodes, and nothing else.
//
// `feltDaySummary(at:)` (CognitiveSubstrate+Mood.swift) says what the day FELT
// like; this says where those feelings CAME FROM, so the nightly dream can cite
// a journal entry it actually felt. It reads the SAME population that summary
// integrates over — identical affect gate, identical `feltDirection` filter,
// identical 24h window — and is just as PURE (`field.peekNodes()` only; no
// persistence, no field mutation, no decay advance).
//
// NO NEW EXPOSURE SURFACE: the summary's named lines are conversation-only
// on purpose (see its exposure note), and nothing here widens that. A felt
// node's SUMMARY TEXT never leaves this function — only its subject reference
// and metadata, which is the minimum a citation needs. Adding a field to this
// struct is adding an exposure surface; don't, without the same review.

import Foundation
import NativeAgentCore
import PersistenceCore

/// Where one felt node came from. Subject + metadata only, deliberately.
public struct CognitiveFeltOrigin: Sendable, Equatable {
    public var subjectType: String
    public var subjectID: String
    /// The node's string-valued metadata. Non-string values are dropped: an id
    /// a consumer can cite is a string, and coercing numbers would invent ones.
    public var metadata: [String: String]

    public init(subjectType: String, subjectID: String, metadata: [String: String]) {
        self.subjectType = subjectType
        self.subjectID = subjectID
        self.metadata = metadata
    }
}

public extension CognitiveSubstrate {
    /// Provenance of the last-24h felt nodes — the same population
    /// `feltDaySummary(at:)` integrates over, strongest-felt first.
    ///
    /// Ordering matches the summary's ranking (|valence| desc, arousal desc,
    /// stable id) so a consumer that keeps only the first N keeps the ones that
    /// mattered most, deterministically across dictionary orderings.
    ///
    /// Empty when cognition or affect is off, or nothing was felt — the same
    /// silence the summary returns nil for.
    func feltDayOrigins(at now: Date) async -> [CognitiveFeltOrigin] {
        guard configuration.enabled, configuration.affectEnabled else { return [] }
        let felt = field.peekNodes().filter { node in
            guard feltDirection(
                valence: node.emotionalValence,
                arousal: node.emotionalArousal,
                warmth: node.emotionalWarmth
            ) != nil else { return false }
            let age = now.timeIntervalSince(node.lastActivatedAt)
            return age >= 0 && age <= Self.moodActivationWindow
        }
        let ranked = felt.sorted { lhs, rhs in
            let lv = abs(lhs.emotionalValence), rv = abs(rhs.emotionalValence)
            if lv != rv { return lv > rv }
            if lhs.emotionalArousal != rhs.emotionalArousal {
                return lhs.emotionalArousal > rhs.emotionalArousal
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return ranked.map { node in
            var metadata: [String: String] = [:]
            for (key, value) in node.metadata {
                if case .string(let text) = value { metadata[key] = text }
            }
            return CognitiveFeltOrigin(
                subjectType: node.subjectReference.type,
                subjectID: node.subjectReference.id,
                metadata: metadata
            )
        }
    }
}
