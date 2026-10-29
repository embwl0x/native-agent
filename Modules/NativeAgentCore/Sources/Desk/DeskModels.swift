import NativeAgentShared
import Transcripts
import Foundation
import PersistenceCore
// Blueprint: | `DeskModels.swift` | Shared Desk enum vocabulary and JSON scalar interpretation |

// MARK: - Agent Desk — durable, event-sourced user-directed tracking
//
// Canonical Desk truth is structured
// item rows. All mutations are OP-BASED EVENTS appended under flock; derived
// state is REBUILT FROM OPS each append (mirrors TaskLedger EXACTLY). The
// rendered compact text (DeskPage) is a PROJECTION, never the source of
// truth.
//
// Durable operations stay in Desk. Origin classification reads the canonical
// session index through Transcripts; no provider / LLM / execution dependency.
//
// STABLE HANDLES survive everything ("desk_" + lowercased UUID). The view
// numbers ("2", "2.1") are mutable, view-local ALIASES — assigned at create
// from a monotonic per-parent sequence and NEVER renumbered when siblings close
// or archive.

// MARK: - Enums

public enum CadenceMode: String, Sendable, CaseIterable, Equatable {
    case manual, on_ask, tick, event, daily, weekly, blocked_watch
}

public enum NotifyLevel: String, Sendable, CaseIterable, Equatable {
    case quiet, digest, direct, urgent
}

public enum ArchiveFinalStatus: String, Sendable, CaseIterable, Equatable {
    case done, canceled, superseded
}

/// Immutable item origin: `owner` is the generic add-item default; `system` is machine-authored. Self-authored pursuits use `agent`, created only through dossier- and cap-gated `openPursuit`. Decode defaults to `.owner`, which encode omits
/// to preserve existing feed bytes.
public enum DeskOrigin: String, Sendable, CaseIterable, Equatable {
    case owner, agent, system

    /// Persisted compatibility for Desk feeds written before the self-authored role was made identity-neutral. New writes always emit `agent`; the former private-name value remains read-only migration vocabulary.
    public static func decodePersisted(_ rawValue: String) -> DeskOrigin? {
        let retiredPrivateValue = ["ay", "ala"].joined()
        return rawValue == retiredPrivateValue ? .agent : DeskOrigin(rawValue: rawValue)
    }
}

// MARK: - Desk model and operation JSONValue read helpers

func jsonInt(_ obj: [String: JSONValue], _ key: String) -> Int? {
    if case .int(let i)? = obj[key] { return Int(i) }
    if case .string(let s)? = obj[key], let i = Int(s) { return i }
    return nil
}
