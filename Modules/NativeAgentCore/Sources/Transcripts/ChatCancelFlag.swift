import Foundation
import os
import PersistenceCore

// Blueprint: | `ChatCancelFlag.swift` | `ChatCancelFlag`: Run-tagged Stop survives later acceptance |

/// Run-tagged Stop markers preserve cancellation across later acceptance. Readable tagged markers match only their runs; empty markers and untagged URLs
/// match any run. An unreadable marker stops work and retains its cause until settlement. URL fragments carry run identity without changing the file path.
/// Stop markers use off-disk backup and PrivacyMap/chat; local backup, export and phone sync exclude them.
public enum ChatCancelFlag {
    public static func path(dataRoot: URL, sessionId: String) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("cancelled.flag")
    }

    /// Carry accepted session and trace identity across every ingress door.
    public struct InFlightTurn: Sendable {
        public let runId: String
        public let sessionId: String
        public let turnId: String
        public let acceptedAt: Date
        public let stop: URL
        fileprivate var readFailure: String? = nil
    }

    /// Register before any await so Stop can name the live run; repeated admission is idempotent and must pair with finish.
    public static func accept(dataRoot: URL, sessionId: String, runId: String, turnId: String) -> URL {
        let file = path(dataRoot: dataRoot, sessionId: sessionId)
        let key = file.standardizedFileURL.path
        var parts = URLComponents(url: file, resolvingAgainstBaseURL: false)
        parts?.fragment = runId
        let stop = parts?.url ?? file
        registry.withLock { runs in
            runs.completed.removeAll { $0 == key }
            if runs.inFlight[key]?.contains(where: { $0.runId == runId }) != true {
                runs.inFlight[key, default: []].append(
                    InFlightTurn(runId: runId, sessionId: sessionId, turnId: turnId, acceptedAt: Date(), stop: stop))
            }
            runs.latest[key] = runId
        }
        NotificationCenter.default.post(name: inFlightDidChange, object: nil)
        return stop
    }

    /// Surface-independent admission and finish events keep other doors' visible turns current.
    public static let inFlightDidChange = Notification.Name("ChatCancelFlag.inFlightDidChange")

    public static func finish(_ flag: URL) {
        guard let runId = flag.fragment else { return }
        let key = URL(fileURLWithPath: flag.path).standardizedFileURL.path
        registry.withLock { runs in
            guard var ids = runs.inFlight[key], let i = ids.firstIndex(where: { $0.runId == runId }) else { return }
            ids.remove(at: i)
            runs.inFlight[key] = ids.isEmpty ? nil : ids
            if ids.isEmpty {
                runs.completed.append(key)
                if runs.completed.count > 256 {
                    runs.latest.removeValue(forKey: runs.completed.removeFirst())
                }
            }
        }
        NotificationCenter.default.post(name: inFlightDidChange, object: nil)
    }

    /// Quit waits for accepted unfinished runs so their settlement can land.
    public static func inFlightRunIDs() -> Set<String> {
        registry.withLock { runs in Set(runs.inFlight.values.joined().map(\.runId)) }
    }

    public static func inFlightTurns(dataRoot: URL) -> [InFlightTurn] {
        registry.withLock { runs in
            runs.inFlight.flatMap { key, turns in
                turns.filter { path(dataRoot: dataRoot, sessionId: $0.sessionId).standardizedFileURL.path == key }
            }
        }
    }

    /// Target in-flight runs, then the last run, otherwise a token no turn can match.
    public static func stopContent(forFlagAt flag: URL) -> String {
        let key = flag.standardizedFileURL.path
        return registry.withLock { runs in
            if let ids = runs.inFlight[key], !ids.isEmpty { return ids.map(\.runId).joined(separator: "\n") }
            return runs.latest[key] ?? "none"
        }
    }

    public static func isRaised(_ flag: URL?) -> Bool {
        guard let flag else { return false }
        if readFailure(flag) != nil { return true }
        let content: String
        do {
            content = try String(contentsOf: URL(fileURLWithPath: flag.path), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        } catch {
            let reason = "Stopped because the Stop marker could not be read: \(error.localizedDescription). Repair \(flag.path) before continuing."
            let firstReadFailure = registry.withLock { runs in
                let key = URL(fileURLWithPath: flag.path).standardizedFileURL.path
                guard let index = runs.inFlight[key]?.firstIndex(where: { $0.stop == flag }) else { return true }
                guard runs.inFlight[key]?[index].readFailure == nil else { return false }
                runs.inFlight[key]?[index].readFailure = reason
                return true
            }
            if firstReadFailure { nativeLog("%@", reason, level: .error) }
            return true
        }
        guard let runId = flag.fragment else { return true }
        return content.isEmpty || content.split(separator: "\n").contains { $0 == runId }
    }

    /// The accepted run owns the observed cause; repairing the file cannot undo its Stop or erase that cause before settlement.
    public static func readFailure(_ flag: URL?) -> String? {
        guard let flag else { return nil }
        let key = URL(fileURLWithPath: flag.path).standardizedFileURL.path
        return registry.withLock { runs in runs.inFlight[key]?.first(where: { $0.stop == flag })?.readFailure }
    }

    private struct Runs {
        var inFlight: [String: [InFlightTurn]] = [:]
        var latest: [String: String] = [:]
        // Keep up to 256 completed sessions for Stop; in-flight sessions stay retained.
        var completed: [String] = []
    }
    private static let registry = OSAllocatedUnfairLock(initialState: Runs())
}
