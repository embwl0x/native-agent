import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `SlackRuntimeDiagnostics.swift` | Checked diagnostic storage; connection evidence reads the live socket owner without a freshness clock |

enum SlackSocketConnections {
    private static let sockets = OSAllocatedUnfairLock(initialState: [String: URLSessionWebSocketTask]())

    static func retain(_ socket: URLSessionWebSocketTask, dataRoot: URL) {
        sockets.withLock { $0[dataRoot.standardizedFileURL.path] = socket }
    }

    static func release(_ socket: URLSessionWebSocketTask, dataRoot: URL) {
        sockets.withLock {
            let key = dataRoot.standardizedFileURL.path
            if $0[key] === socket { $0.removeValue(forKey: key) }
        }
    }

    static func current(dataRoot: URL) -> URLSessionWebSocketTask? {
        sockets.withLock { $0[dataRoot.standardizedFileURL.path] }
    }
}

/// Unreadable diagnostic evidence must not be overwritten and misrepresented as fresh healthy state.
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
                guard patch.contains(where: { object[$0.key] != $0.value }) else { return .stored }
                for (key, value) in patch {
                    object[key] = value
                }
                object["updatedAt"] = .string(NativeTimestampFormat.fractionalZulu(now))
                try await SwiftNativePersistenceCore.writeJSON(.object(object), to: statePath)
                return .stored
            }
        } catch {
            return .unavailableWriteFailure
        }
    }
}

/// Saved connection evidence requires its live socket owner; elapsed time cannot decide connection state.
public enum SlackRuntimeStateFeed {

    public struct Snapshot: Equatable, Sendable {
        public let connected: Bool
        public let updatedAt: String
        public let hasReportedError: Bool
        public let lastError: String?
    }

    public enum Observation: Equatable, Sendable {
        case absent
        case current(Snapshot)
        case unavailable(String)
    }

    public static func read(dataRoot: URL) -> Observation {
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
                  NativeTimestampFormat.parseISO8601FractionalFirst(updatedAt) != nil else {
                return .unavailable("Slack runtime state has no valid update timestamp")
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
            if connected {
                guard let socket = SlackSocketConnections.current(dataRoot: dataRoot), socket.state == .running else {
                    return .unavailable("Saved Slack connection has no running socket owner; wait for Socket Mode to connect or switch it off.")
                }
            }
            return .current(snapshot)
        } catch {
            return .unavailable("Slack runtime state could not be read: \(error.localizedDescription)")
        }
    }
}
