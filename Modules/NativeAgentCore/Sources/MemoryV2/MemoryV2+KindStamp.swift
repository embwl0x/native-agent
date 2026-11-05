// Preserve supplied kinds; stamp absent kinds as general without decay changes. `write_default_v1` keeps machine defaults eligible for approved classification,
// while unsourced kinds remain deliberate caller signals.

import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MemoryV2+KindStamp.swift` | `MemoryKindStamp`, `writerKinds`, `personKinds`: shared kind vocabulary and conservative defaults |

public enum MemoryKindStamp {

    /// General has no decay half-life; every replacement still requires explicit intent.
    public static let defaultKind = "general"

    /// kind_source for the write-time default stamp. Rows carrying this source are still classifiable by the approval-gated backfill.
    public static let writeDefaultSource = "write_default_v1"

    public static let backfillSource = "backfill_llm_v1"

    /// One kind vocabulary serves the memory writer, explicit saves and person-picture admission.
    public static let writerKinds: [String] = [
        "identity", "location", "employment", "schedule", "preference",
        "relationship", "goal", "skill", "fact", "correction",
    ]

    public static let commitKinds = writerKinds + ["instruction", genericCommitKind]

    /// The person picture and pinned core admit these person kinds, including persisted labels. Other kinds remain fully recallable outside the picture.
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

    /// Share kind extraction with recall scoring: empty strings are absent.
    public static func kind(of metadata: JSONValue?) -> String? {
        MemoryRecallScoring.kind(of: metadata)
    }

    public static func kindSource(of metadata: JSONValue?) -> String? {
        guard case .object(let obj)? = metadata,
              case .string(let s)? = obj["kind_source"], !s.isEmpty else { return nil }
        return s
    }

    /// Existing kinds always win; preserve non-object metadata rather than destroying an unknown shape.
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

    /// Classify only missing kinds, machine defaults and unsourced notes; preserve deliberate kinds and content.
    public static func isClassifiable(_ metadata: JSONValue?) -> Bool {
        guard let k = kind(of: metadata) else { return true }
        let source = kindSource(of: metadata)
        if k == genericCommitKind, source == nil { return true }
        return k == defaultKind && source == writeDefaultSource
    }
}
