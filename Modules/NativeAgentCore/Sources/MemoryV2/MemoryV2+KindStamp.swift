// Every store write preserves a supplied kind or stamps "general" with kind_source "write_default_v1".
// The default leaves decay unchanged; classification and decay rates require agent/user approval.
//
// kind_source provenance keeps default-stamped rows visible to future
// backfill passes: "write_default_v1" means "machine default, still
// classifiable"; a kind without kind_source means a deliberate caller signal.

import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MemoryV2+KindStamp.swift` | `MemoryKindStamp`: conservative write-time memory kind and source metadata defaults; the one kind vocabulary (`writerKinds`, `personKinds`) the writer, the explicit save and the person picture share |

public enum MemoryKindStamp {

    /// Default kind for writes that carry no kind signal. NOT in
    /// `memoryDecayHalfLifeDays` (decayFactor 1.0). Replacement always requires
    /// explicit intent, regardless of kind.
    public static let defaultKind = "general"

    /// kind_source for the write-time default stamp. Rows carrying this
    /// source are still classifiable by the approval-gated backfill.
    public static let writeDefaultSource = "write_default_v1"

    /// kind_source written by the approval-gated LLM backfill apply path.
    public static let backfillSource = "backfill_llm_v1"

    /// One kind vocabulary serves the memory writer, explicit saves and person-picture admission.
    public static let writerKinds: [String] = [
        "identity", "location", "employment", "schedule", "preference",
        "relationship", "goal", "skill", "fact", "correction",
    ]

    /// The person picture and pinned core admit these person kinds, including persisted labels.
    /// Other kinds remain fully recallable outside the picture.
    public static let personKinds: Set<String> = [
        "identity", "location", "employment", "schedule", "preference",
        "relationship", "user_fact", "user_preference", "attribute",
    ]

    /// A generic `note` without kind_source remains classifiable.
    public static let genericCommitKind = "note"

    /// Backfill's allow-list includes every writer-named person kind; explicit caller kinds pass through stamping unchanged.
    public static let taxonomy: [String] = [
        "identity", "relationship", "preference", "attribute",
        "location", "employment", "schedule", "goal", "skill",
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

    /// Backfill classifies missing kinds, machine defaults or unsourced `note` rows; deliberate kinds are never re-proposed.
    /// Backfill changes kind metadata without touching content.
    public static func isClassifiable(_ metadata: JSONValue?) -> Bool {
        guard let k = kind(of: metadata) else { return true }
        let source = kindSource(of: metadata)
        if k == genericCommitKind, source == nil { return true }
        return k == defaultKind && source == writeDefaultSource
    }
}
