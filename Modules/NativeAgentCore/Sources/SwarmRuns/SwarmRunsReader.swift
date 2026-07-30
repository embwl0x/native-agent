// Reader protocol + factory for the read-only agent-swarm RUN-LIST surface.
//
// Mirrors the wave-pattern used by KnowledgeGraph / MacAssistantStatus:
//   - a `SwarmRunsReader` protocol with the one read call,
//   - `SwiftNativeSwarmRunsReader` (reads the local JSON file each call),
//   - `makeSwarmRunsReader()` factory.
//
// The SwiftNative reader returns the SAME envelope the daemon GET route does:
//   GET /v1/agent/swarms -> {"status": "ready", "runs": [...], "createdAt": <iso>}
// Run objects are passthrough from the stored file (no field reshaping). The
// `createdAt` envelope field is the RESPONSE timestamp (the daemon route emits
// `now_iso()` per call), so it is generated fresh here too; it is NOT the run's
// own createdAt (which lives inside each element of `runs`).
//
// NOTE: this read-side port lands DORMANT. The single LIVE Mac-UI consumer of
// the operating-map snapshot family does NOT fetch /v1/agent/swarms (only smoke
// scripts hit it), and the GET would only be safe to serve natively once the
// cross-process flock wraps every Python write of swarms/runs.json (the
// POST /v1/agent/swarms/run executor mutates it). Default OFF. See
// CUTOVER_PLAN.md §6.55 for the named retirement prereqs.

import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Protocol

public protocol SwarmRunsReader: Sendable {
    /// GET /v1/agent/swarms — the full `{"status","runs","createdAt"}` envelope,
    /// or nil when no native data is available.
    func listSwarms(limit: Int) async -> JSONValue?
}

public extension SwarmRunsReader {
    /// Default-limit convenience matching the daemon ROUTE, which calls
    /// `list_agent_swarms()` with the method default `limit=50`
    ///. Swift protocol REQUIREMENTS can't carry a
    /// default argument, so a caller holding `any SwarmRunsReader` would
    /// otherwise have to pass `limit:` explicitly; this extension restores the
    /// route's default at the call site.
    func listSwarms() async -> JSONValue? { await listSwarms(limit: 50) }
}

// MARK: - SwiftNative impl

public struct SwiftNativeSwarmRunsReader: SwarmRunsReader {
    /// Absolute path to `<dataRoot>/swarms/runs.json`.
    public let runsPath: URL

    public init(runsPath: URL) {
        self.runsPath = runsPath
    }

    /// Resolve the path the daemon uses:
    ///   the retired daemon `self.agent_swarms_path = root / "swarms" / "runs.json"`
    /// where `root` is the data root. PersistenceCore.defaultDataRoot() mirrors
    /// the daemon's data-root resolution (env NATIVE_AGENT_DATA_ROOT, literal
    /// tilde, default ~/.nativeagent).
    public static func defaultPath() -> URL {
        PersistenceCore.defaultDataRoot()
            .appendingPathComponent("swarms", isDirectory: true)
            .appendingPathComponent("runs.json")
    }

    public func listSwarms(limit: Int = 50) async -> JSONValue? {
        let store = SwarmRunsStore.load(path: runsPath)
        let runs = store.listAgentSwarms(limit: limit)
        // Mirror the daemon ROUTE envelope. `createdAt`
        // is the response timestamp (route emits now_iso()), generated fresh per
        // call to match HTTP.
        return .object([
            "status": .string("ready"),
            "runs": .array(runs),
            "createdAt": .string(Self.nowISO()),
        ])
    }

    /// Reproduce the daemon's `now_iso()` shape EXACTLY:
    ///   `datetime.now(timezone.utc).isoformat()`
    /// which renders microseconds and a `+00:00` UTC offset (NOT a `Z` suffix),
    /// e.g. "2026-06-01T17:08:42.123456+00:00". Python omits the microsecond
    /// fraction entirely when it happens to be 0 ("...T17:08:42+00:00"); that
    /// boundary is vanishingly rare and the field is non-load-bearing (no
    /// consumer parses this envelope timestamp), so we always emit 6 fractional
    /// digits — the common-case format — rather than special-casing zero.
    static func nowISO() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return f.string(from: Date())
    }
}

// MARK: - Factory

/// Returns the SwiftNative reader. `runsPath` is injectable for tests; production
/// callers omit it and get `defaultPath()`.
public func makeSwarmRunsReader(
    runsPath: URL? = nil
) -> any SwarmRunsReader {
    return SwiftNativeSwarmRunsReader(
        runsPath: runsPath ?? SwiftNativeSwarmRunsReader.defaultPath()
    )
}
