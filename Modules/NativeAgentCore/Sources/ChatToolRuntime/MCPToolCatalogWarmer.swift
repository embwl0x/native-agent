import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
import MCPDispatcher

// MARK: - MCP tools-cache warm (production trigger)

/// Nonblocking catalog warm trigger. MCPToolBridge reads the persisted catalog;
/// this owner delegates discovery to MCPWarmSweepLedger. One bounded sweep runs
/// at a time, with a minimum rearm interval so catalog builds cannot fan out
/// into a subprocess storm.
package actor MCPToolCatalogWarmer {
    package static let shared = MCPToolCatalogWarmer()

    /// Minimum gap between sweeps. A chat turn builds the catalog repeatedly;
    /// only the first build in a window may spawn subprocesses.
    static let rearmInterval: TimeInterval = 300
    /// Hard ceiling on one sweep. A wedged server gets cancelled, not waited on.
    static let sweepDeadline: TimeInterval = 30
    /// Launch is already busy: the first sweep starts no sooner than this long
    /// after the process did. A kick before then schedules that one sweep.
    static let launchDelay: TimeInterval = 60

    /// When this process started, from the kernel's own record.
    static let processStartedAt: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let started = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }()

    private var lastStartedAt: Date?
    private var inFlight = false
    private let firstSweepAt = MCPToolCatalogWarmer.processStartedAt.addingTimeInterval(MCPToolCatalogWarmer.launchDelay)
    private var firstSweepScheduled = false

    private static func liveSweep(_ root: URL) async {
        let report = await MCPWarmSweepLedger.shared.sweep(root: root)
        let refreshed = report.values.filter { $0 != "skipped" && !$0.hasPrefix("error") }.count
        let failed = report.values.filter { $0.hasPrefix("error") }.count
        let note = "\(refreshed) refreshed, \(failed) failed, \(report.count - refreshed - failed) unchanged"
        // Every handshake it tried failed: evidence, never a healthy pulse.
        if refreshed == 0, failed > 0 {
            OrganPulse.record("mcp_warm_sweep", .skipped, note: note)
        } else {
            OrganPulse.record("mcp_warm_sweep", found: refreshed, note: note)
        }
    }

    /// Synchronous, allocation-cheap entry point for the tool-catalog build.
    /// Returns immediately; every decision happens on the actor.
    package nonisolated func kickDetached(dataRoot: URL) {
        Task.detached(priority: .utility) { [self] in
            await kickIfDue(dataRoot: dataRoot)
        }
    }

    /// True when this call actually started a sweep. False when one is already
    /// running or the re-arm window has not elapsed.
    @discardableResult
    func kickIfDue(dataRoot: URL) async -> Bool {
        guard !inFlight else { return false }
        let now = Date()
        if lastStartedAt == nil, now < firstSweepAt {
            if !firstSweepScheduled {
                firstSweepScheduled = true
                let wait = firstSweepAt.timeIntervalSince(now)
                Task { [self] in
                    try? await Task.sleep(for: .seconds(wait))
                    await kickIfDue(dataRoot: dataRoot)
                }
            }
            return false
        }
        if let last = lastStartedAt, now.timeIntervalSince(last) < Self.rearmInterval {
            return false
        }
        lastStartedAt = now
        inFlight = true
        Task { await self.runBoundedSweep(dataRoot: dataRoot) }
        return true
    }

    private func runBoundedSweep(dataRoot: URL) async {
        try? await TurnDeadline.withThrowingDeadline(seconds: Self.sweepDeadline) {
            await Self.liveSweep(dataRoot)
        }
        inFlight = false
    }
}

// MARK: - Warm-sweep per-server change gate (perf wave 2, F6)

/// Decides which stdio servers a warm sweep actually has to handshake.
///
/// A full live refresh forces a `tools/list` round-trip for EVERY
/// configured server on every sweep — and because the subprocess pool reaps
/// idle servers, a 300s-cadence sweep re-spawns each of them, waits out the
/// handshake, and rewrites `mcp/cache/tools.json` with descriptors that are
/// byte-for-byte the ones already there. This ledger skips the servers that
/// provably cannot have changed and sweeps the rest exactly as before.
///
/// A server is skipped only when ALL of these hold:
///   • its manifest sources — `mcp/servers.json` and `research/config.json`,
///     which is where the auto-merged `searxng-local` default comes from — are
///     byte-identical (device, inode, size, mtime_ns) to the last SUCCESSFUL
///     handshake's, and
///   • its own command line (transport, endpoint, command, status) is
///     unchanged, and
///   • that handshake is younger than `maxHandshakeAge`.
///
/// The shared execution identity observes executable/script bytes and offline
/// npm package versions, including cached @latest upgrades. The age ceiling
/// still refreshes remote catalogs and unresolved package launches.
/// A failed handshake never marks, so a broken server retries on every sweep.
actor MCPWarmSweepLedger {
    static let shared = MCPWarmSweepLedger()

    /// Age must exceed the warmer's five-minute cadence to skip unchanged
    /// handshakes. Remote catalog changes are rediscovered within an hour;
    /// local execution identity changes invalidate the next sweep's mark.
    static let maxHandshakeAge: TimeInterval = 60 * 60

    struct Signature: Sendable, Equatable {
        let manifest: String
        let commandLine: String
    }

    private struct Mark: Sendable {
        let signature: Signature
        let at: Date
    }

    /// key: "<resolved root path>|<serverId>"
    private var marks: [String: Mark] = [:]

    /// Never throws: returns
    /// serverId → tool count or error text, and logs every failure and every
    /// zero-tool result loudly. Skipped servers are reported as "skipped" and
    /// leave `mcp/cache/tools.json` untouched — which is the point: their
    /// catalog bytes are already the bytes a handshake would rewrite.
    @discardableResult
    func sweep(root: URL) async -> [String: String] {
        let dispatcher = SwiftNativeMCPDispatcher(root: root)
        let servers = (try? await dispatcher.listServers()) ?? []
        let manifest = await Self.manifestStamp(dispatcher: dispatcher)
        let rootKey = root.resolvingSymlinksInPath().path
        let now = Date()

        var report: [String: String] = [:]
        var liveKeys: Set<String> = []
        for server in servers where server.status != "needs_setup" && server.status != "error" {
            let key = "\(rootKey)|\(server.id)"
            liveKeys.insert(key)
            let signature = Signature(manifest: manifest, commandLine: Self.commandLine(server))
            if let mark = marks[key],
               mark.signature == signature,
               now.timeIntervalSince(mark.at) >= 0,
               now.timeIntervalSince(mark.at) < Self.maxHandshakeAge {
                report[server.id] = "skipped"
                continue
            }
            do {
                let count = try await dispatcher.refreshToolsCache(forServer: server.id)
                // MARK ON SUCCESS ONLY. A server that threw, or that has not
                // completed a handshake at all, must stay on the sweep list.
                marks[key] = Mark(signature: signature, at: now)
                report[server.id] = "\(count)"
                if count == 0 {
                    FileHandle.standardError.write(Data(
                        "MCPDispatcher: server '\(server.id)' completed tools/list but advertised ZERO tools — it will contribute no mcp__\(server.id)__* descriptors to the model.\n".utf8
                    ))
                }
            } catch {
                report[server.id] = "error: \(error)"
                FileHandle.standardError.write(Data(
                    "MCPDispatcher: tools-cache refresh FAILED for server '\(server.id)': \(error) — its tools stay invisible to the model.\n".utf8
                ))
            }
        }
        // Every insert has a matching remove: a server deleted from the
        // manifest, or a data root that will never be swept again, must not
        // hold a mark for the process lifetime.
        marks = marks.filter { !$0.key.hasPrefix("\(rootKey)|") || liveKeys.contains($0.key) }
        return report
    }

    /// The manifest sources' combined stat identity. Both files feed
    /// `listServers()`: `servers.json` is the manifest proper, and
    /// `research/config.json` supplies `searxng_base_url` for the auto-merged
    /// default server, so a change to either can change a server's command
    /// line without touching the other.
    private static func manifestStamp(dispatcher: SwiftNativeMCPDispatcher) async -> String {
        let paths = [await dispatcher.serversPath, await dispatcher.configPath]
        return paths.map(fileStamp).joined(separator: "|")
    }

    /// stat-strength, with "does not exist" as a distinct value from "could not
    /// be stat'd" — the latter is unknowable, so it never compares equal to
    /// itself and the server is always swept.
    private static func fileStamp(_ url: URL) -> String {
        var info = stat()
        if stat(url.path, &info) == 0 {
            return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        }
        return errno == ENOENT ? "absent" : "unknown:\(UUID().uuidString)"
    }

    /// The server's own identity within the manifest. Deliberately built from
    /// named scalar fields in a fixed order rather than by serializing the
    /// record: dictionary serialization has no guaranteed key order, and a
    /// signature that flaps would either never skip or skip on a false match.
    private static func commandLine(_ server: MCPServer) -> String {
        [
            server.transport,
            server.endpoint,
            server.command ?? "",
            server.status,
            (try? server.executionIdentity()) ?? "unavailable:\(UUID().uuidString)",
        ].joined(separator: "\u{1F}")
    }

}
