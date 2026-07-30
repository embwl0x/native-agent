// U3 wave-2 item 5a (2026-06-10): write-time kind stamping.
//
// Audit fact: decay/supersession shipped in wave 1 but are inert on 100% of
// rows because ALL 32 live rows lack metadata.kind. This file is the
// write-side half of the fix: every NEW write through the store path gets a
// metadata.kind. The signal rule is deliberately conservative — memory
// SEMANTICS (kinds, decay rates, supersession) are Agent/user-owned:
//
//   * caller/extractor-provided kind (the #1 signal-carry that already flows
//     through propose() → acceptProposal()) is honored verbatim and NEVER
//     overwritten — it is the cheapest reliable signal available at write
//     time;
//   * absent that, the row is stamped kind "general" + kind_source
//     "write_default_v1". "general" maps to decayFactor 1.0 (it is not in
//     memoryDecayHalfLifeDays) and is not in
//     memorySupersessionSingleValuedKinds, so behavior is UNCHANGED until
//     Agent/the user approve kinds/rates. We do NOT regex-guess identity/location/
//     employment at write time: a heuristic stamp in those kinds would
//     activate the supersession archiver on the next approved hygiene run
//     without any human having seen the label. Real classification is the
//     approval-gated LLM backfill (MemoryV2+KindBackfill.swift).
//
// kind_source provenance keeps default-stamped rows visible to future
// backfill passes: "write_default_v1" means "machine default, still
// classifiable"; a kind without kind_source means a deliberate caller signal.

import Foundation
import NativeAgentCore
import PersistenceCore

public enum MemoryKindStamp {

    /// Default kind for writes that carry no kind signal. NOT in
    /// `memoryDecayHalfLifeDays` (decayFactor 1.0) and NOT in
    /// `memorySupersessionSingleValuedKinds` — semantics-neutral by
    /// construction.
    public static let defaultKind = "general"

    /// kind_source for the write-time default stamp. Rows carrying this
    /// source are still classifiable by the approval-gated backfill.
    public static let writeDefaultSource = "write_default_v1"

    /// kind_source written by the approval-gated LLM backfill apply path.
    public static let backfillSource = "backfill_llm_v1"

    /// Canonical kind taxonomy (the union of every kind the repo's memory
    /// semantics already name — one allow-list so the LLM backfill can't
    /// invent labels):
    ///   - memorySupersessionSingleValuedKinds: identity, location, employment
    ///   - memoryDecayHalfLifeDays:             volatile, project, operational
    ///   - AdaptiveMemoryPromoter emits:        identity, location, employment,
    ///                                          preference, attribute
    ///   - FM fact-extractor categories:        identity, preference,
    ///                                          relationship, goal, skill
    ///   - write-time default:                  general
    /// Rates/half-lives per kind stay Agent/user-owned; this list only bounds
    /// what a classifier may propose.
    public static let taxonomy: [String] = [
        "identity", "relationship", "preference", "attribute",
        "location", "employment", "goal", "skill",
        "project", "operational", "volatile",
        "general",
    ]

    /// The kind carried in a metadata blob (same convention as
    /// `MemoryRecallScoring.kind(of:)` — metadata.kind, empty string = nil).
    public static func kind(of metadata: JSONValue?) -> String? {
        MemoryRecallScoring.kind(of: metadata)
    }

    /// The kind_source provenance marker, when present.
    public static func kindSource(of metadata: JSONValue?) -> String? {
        guard case .object(let obj)? = metadata,
              case .string(let s)? = obj["kind_source"], !s.isEmpty else { return nil }
        return s
    }

    /// Stamp the write-time default kind into `metadata` IFF it carries no
    /// kind signal. Caller-provided kinds pass through untouched (existing
    /// keys always win). Non-object metadata is returned verbatim — never
    /// destroy what we don't understand.
    public static func stampingDefaultKind(_ metadata: JSONValue?) -> JSONValue? {
        switch metadata {
        case nil:
            return .object([
                "kind": .string(defaultKind),
                "kind_source": .string(writeDefaultSource),
            ])
        case .object(var obj)?:
            if case .string(let k)? = obj["kind"], !k.isEmpty { return metadata }
            obj["kind"] = .string(defaultKind)
            obj["kind_source"] = .string(writeDefaultSource)
            return .object(obj)
        default:
            return metadata
        }
    }

    /// True when the approval-gated backfill may (re)classify this row:
    /// either no kind at all (the 32 legacy rows), or only the machine
    /// write-default stamp. A kind without the write-default source is a
    /// deliberate signal (caller, extractor, or an approved backfill) and is
    /// never re-proposed.
    public static func isClassifiable(_ metadata: JSONValue?) -> Bool {
        guard let k = kind(of: metadata) else { return true }
        return k == defaultKind && kindSource(of: metadata) == writeDefaultSource
    }
}
