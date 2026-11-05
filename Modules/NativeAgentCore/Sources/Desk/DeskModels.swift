import NativeAgentShared
import Transcripts
import Foundation
import PersistenceCore
// Blueprint: | `DeskModels.swift` | Shared Desk enum vocabulary and JSON scalar interpretation |

// MARK: - Agent Desk — durable, event-sourced user-directed tracking
// Structured rows are canonical; flocked events rebuild state and text is only a projection.
// Origin reads the canonical session index without provider or execution dependencies.
// Stable handles identify items; monotonic per-parent aliases never renumber when siblings close.

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

/// Only dossier- and cap-gated openPursuit creates agent origin; omitted origin means owner.
public enum DeskOrigin: String, Sendable, CaseIterable, Equatable {
    case owner, agent, system

}

// MARK: - Desk model and operation JSONValue read helpers

func jsonInt(_ obj: [String: JSONValue], _ key: String) -> Int? {
    if case .int(let i)? = obj[key] { return Int(i) }
    if case .string(let s)? = obj[key], let i = Int(s) { return i }
    return nil
}

/// Omitted collections are empty; present collections must decode completely so no stored member is lost.
func deskStoredCollection<T>(_ value: JSONValue?, decode: (JSONValue) -> T?) -> [T]? {
    guard let value else { return [] }
    guard case .array(let rows) = value else { return nil }
    var result: [T] = []
    for row in rows {
        guard let decoded = decode(row) else { return nil }
        result.append(decoded)
    }
    return result
}

enum DeskJSON {
    static func optionalStringsAreValid(_ object: [String: JSONValue], keys: [String]) -> Bool {
        keys.allSatisfy { key in
            guard let value = object[key] else { return true }
            if case .string = value { return true }
            return false
        }
    }

    static func strings(_ value: JSONValue?, defaultWhenAbsent: Bool = true) -> [String]? {
        guard let value else { return defaultWhenAbsent ? [] : nil }
        return deskStoredCollection(value) { value in
            guard case .string(let string) = value else { return nil }
            return string
        }
    }

    static func collection<T>(_ value: JSONValue?, decode: (JSONValue) -> T?) -> [T]? {
        deskStoredCollection(value, decode: decode)
    }
}
