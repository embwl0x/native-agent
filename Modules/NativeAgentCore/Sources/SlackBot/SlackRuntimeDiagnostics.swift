import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SlackRuntimeDiagnostics.swift` | `SlackRuntimeStateWriteOutcome` enum |

/// Result of patching the loop's diagnostic state. State is observational, but
/// an existing unreadable file is still evidence: it must not be overwritten
/// and then misrepresented as a fresh healthy state.
enum SlackRuntimeStateWriteOutcome: Sendable, Equatable {
    case stored
    case unavailableMalformedExistingState
    case unavailableWriteFailure
}

enum SlackRuntimeStateStore {
    static func path(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("slack", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    static func apply(
        _ patch: [String: JSONValue],
        dataRoot: URL,
        now: Date = Date()
    ) async -> SlackRuntimeStateWriteOutcome {
        let statePath = path(dataRoot: dataRoot)
        do {
            return try await SwiftNativePersistenceCore.withFileLock(statePath) {
                var object: [String: JSONValue] = [:]
                if FileManager.default.fileExists(atPath: statePath.path) {
                    let bytes = try Data(contentsOf: statePath)
                    let decoded: JSONValue
                    do {
                        decoded = try JSONValue.parse(bytes)
                    } catch {
                        return .unavailableMalformedExistingState
                    }
                    guard case .object(let existing) = decoded else {
                        return .unavailableMalformedExistingState
                    }
                    object = existing
                }
                for (key, value) in patch {
                    object[key] = value
                }
                // `state.json` is a runtime feed, not merely an accumulation
                // of diagnostic keys. Its update time lets readers distinguish
                // a quiet-but-live socket (kept fresh by ping) from a bridge
                // that stopped reporting altogether.
                object["updatedAt"] = .string(NativeTimestampFormat.fractionalZulu(now))
                try await SwiftNativePersistenceCore.writeJSON(.object(object), to: statePath)
                return .stored
            }
        } catch {
            return .unavailableWriteFailure
        }
    }
}

/// Typed reader for the Socket Mode runtime feed. Missing evidence, malformed
/// state, and a stale heartbeat are intentionally separate from a fresh
/// disconnected state: none of the former can safely be rendered as a healthy
/// Slack bridge.
public enum SlackRuntimeStateFeed {
    public static let staleAfter: TimeInterval = 90

    public struct Snapshot: Equatable, Sendable {
        public let connected: Bool
        public let updatedAt: String
        public let hasReportedError: Bool
        public let lastError: String?
    }

    public enum Observation: Equatable, Sendable {
        case absent
        case current(Snapshot)
        case stale(Snapshot)
        case unavailable(String)
    }

    public static func read(
        dataRoot: URL,
        now: Date = Date(),
        staleAfter: TimeInterval = SlackRuntimeStateFeed.staleAfter
    ) -> Observation {
        let path = SlackRuntimeStateStore.path(dataRoot: dataRoot)
        var stateDirectoryIsDirectory = ObjCBool(false)
        let stateDirectory = path.deletingLastPathComponent()
        if FileManager.default.fileExists(
            atPath: stateDirectory.path,
            isDirectory: &stateDirectoryIsDirectory
        ), !stateDirectoryIsDirectory.boolValue {
            return .unavailable("Slack runtime state root is not a directory")
        }
        guard FileManager.default.fileExists(atPath: path.path) else { return .absent }
        do {
            let bytes = try Data(contentsOf: path)
            guard case .object(let object) = try JSONValue.parse(bytes) else {
                return .unavailable("Slack runtime state is not a JSON object")
            }
            guard case .bool(let connected)? = object["connected"] else {
                return .unavailable("Slack runtime state has no boolean connection flag")
            }
            guard case .string(let updatedAt)? = object["updatedAt"],
                  let date = NativeTimestampFormat.parseISO8601FractionalFirst(updatedAt) else {
                return .unavailable("Slack runtime state has no valid update timestamp")
            }
            guard date <= now else {
                return .unavailable("Slack runtime state timestamp is in the future")
            }

            let hasReportedError: Bool
            if let errorValue = object["lastError"] {
                switch errorValue {
                case .null:
                    hasReportedError = false
                case .string(let error):
                    hasReportedError = !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                default:
                    return .unavailable("Slack runtime state has an invalid error field")
                }
            } else {
                hasReportedError = false
            }

            let snapshot = Snapshot(
                connected: connected,
                updatedAt: updatedAt,
                hasReportedError: hasReportedError,
                lastError: {
                    if case .string(let detail)? = object["lastError"] { return detail }
                    return nil
                }()
            )
            return now.timeIntervalSince(date) > max(0, staleAfter)
                ? .stale(snapshot)
                : .current(snapshot)
        } catch {
            return .unavailable("Slack runtime state could not be read: \(error.localizedDescription)")
        }
    }
}
