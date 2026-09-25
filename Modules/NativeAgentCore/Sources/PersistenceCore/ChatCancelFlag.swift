import Foundation

/// The session's Stop marker, `chat/sessions/<id>/cancelled.flag`, keyed by
/// run identity. Each accepted turn registers its run id and watches the
/// marker through a URL carrying that id (in its fragment, which `.path`
/// ignores). A Stop writes the run ids in flight on the session (or its last
/// run) INTO the marker, and a turn counts it only when its own id is there.
/// Acceptance used to delete the marker instead, so a bridge turn accepted
/// right after a Mac Stop erased that Stop before the turn it was meant for
/// saw it. Empty content (older writers, tests) and an untagged URL count any
/// marker; a stale marker naming an old run never matches a new one.
public enum ChatCancelFlag {
    public static func path(dataRoot: URL, sessionId: String) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("cancelled.flag")
    }

    /// Registers `runId` as in flight on the session; pair with `finish`.
    public static func accept(dataRoot: URL, sessionId: String, runId: String) -> URL {
        let file = path(dataRoot: dataRoot, sessionId: sessionId)
        registry.withLock { runs in
            runs.inFlight[file.standardizedFileURL.path, default: []].append(runId)
            runs.latest[file.standardizedFileURL.path] = runId
        }
        guard var parts = URLComponents(url: file, resolvingAgainstBaseURL: false) else { return file }
        parts.fragment = runId
        return parts.url ?? file
    }

    public static func finish(_ flag: URL) {
        guard let runId = flag.fragment else { return }
        let key = URL(fileURLWithPath: flag.path).standardizedFileURL.path
        registry.withLock { runs in
            guard var ids = runs.inFlight[key], let i = ids.firstIndex(of: runId) else { return }
            ids.remove(at: i)
            runs.inFlight[key] = ids.isEmpty ? nil : ids
        }
    }

    /// What a Stop writes: the runs in flight on this marker's session, else
    /// its last run, else a token no turn matches.
    public static func stopContent(forFlagAt flag: URL) -> String {
        let key = flag.standardizedFileURL.path
        return registry.withLock { runs in
            if let ids = runs.inFlight[key], !ids.isEmpty { return ids.joined(separator: "\n") }
            return runs.latest[key] ?? "none"
        }
    }

    public static func isRaised(_ flag: URL?) -> Bool {
        guard let flag else { return false }
        guard let runId = flag.fragment else {
            return FileManager.default.fileExists(atPath: flag.path)
        }
        guard let data = FileManager.default.contents(atPath: flag.path) else { return false }
        let content = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty || content.split(separator: "\n").contains { $0 == runId }
    }

    private struct Runs {
        var inFlight: [String: [String]] = [:]
        var latest: [String: String] = [:]
    }
    private static let registry = Locked()
    private final class Locked: @unchecked Sendable {
        private let lock = NSLock()
        private var runs = Runs()
        func withLock<T>(_ body: (inout Runs) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(&runs)
        }
    }
}
