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
actor MCPToolCatalogWarmer {
    typealias Sweep = @Sendable (URL) async -> Void

    static let shared = MCPToolCatalogWarmer()

    /// Minimum gap between sweeps. A chat turn builds the catalog repeatedly;
    /// only the first build in a window may spawn subprocesses.
    static let rearmInterval: TimeInterval = 300
    /// Hard ceiling on one sweep. A wedged server gets cancelled, not waited on.
    static let sweepDeadline: TimeInterval = 30

    private let sweep: Sweep
    private let clock: @Sendable () -> Date
    private let rearmInterval: TimeInterval
    private let sweepDeadline: TimeInterval
    private var lastStartedAt: Date?
    private var inFlight = false
    /// Test seam: sweeps that ran to completion (or were deadline-cancelled).
    private(set) var finishedSweeps = 0

    init(
        sweep: @escaping Sweep = MCPToolCatalogWarmer.liveSweep,
        clock: @escaping @Sendable () -> Date = { Date() },
        rearmInterval: TimeInterval = MCPToolCatalogWarmer.rearmInterval,
        sweepDeadline: TimeInterval = MCPToolCatalogWarmer.sweepDeadline
    ) {
        self.sweep = sweep
        self.clock = clock
        self.rearmInterval = rearmInterval
        self.sweepDeadline = sweepDeadline
    }

    static let liveSweep: Sweep = { root in
        _ = await MCPWarmSweepLedger.shared.sweep(root: root)
    }

    /// Synchronous, allocation-cheap entry point for the tool-catalog build.
    /// Returns immediately; every decision happens on the actor.
    nonisolated func kickDetached(dataRoot: URL) {
        Task.detached(priority: .utility) { [self] in
            await kickIfDue(dataRoot: dataRoot)
        }
    }

    /// True when this call actually started a sweep. False when one is already
    /// running or the re-arm window has not elapsed.
    @discardableResult
    func kickIfDue(dataRoot: URL) async -> Bool {
        guard !inFlight else { return false }
        let now = clock()
        if let last = lastStartedAt, now.timeIntervalSince(last) < rearmInterval {
            return false
        }
        lastStartedAt = now
        inFlight = true
        Task { await self.runBoundedSweep(dataRoot: dataRoot) }
        return true
    }

    private func runBoundedSweep(dataRoot: URL) async {
        let sweep = self.sweep
        let deadline = self.sweepDeadline
        // Deliberately NOT a task group: a group awaits every child before it
        // returns, so a sweep that ignores cancellation (an MCP subprocess
        // wedged inside a `tools/list` round-trip is exactly that) would pin
        // `inFlight` forever and the warmer could never refresh again. The
        // one-shot latch lets the DEADLINE release the slot whether or not the
        // sweep ever notices it was cancelled.
        let latch = OneShotLatch()
        let work = Task.detached(priority: .utility) {
            await sweep(dataRoot)
            await latch.fire()
        }
        let timer = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            await latch.fire()
        }
        await latch.wait()
        work.cancel()
        timer.cancel()
        inFlight = false
        finishedSweeps += 1
    }

    /// Test seam.
    func _testState() -> (inFlight: Bool, finished: Int, lastStartedAt: Date?) {
        (inFlight, finishedSweeps, lastStartedAt)
    }
}

// MARK: - Warm-sweep per-server change gate (perf wave 2, F6)

/// Decides which stdio servers a warm sweep actually has to handshake.
///
/// `refreshAllToolsCaches` forces a live `tools/list` round-trip for EVERY
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

    private let maxHandshakeAge: TimeInterval
    private let clock: @Sendable () -> Date
    /// key: "<resolved root path>|<serverId>"
    private var marks: [String: Mark] = [:]
    /// Test seam: servers actually handshaken across this ledger's lifetime.
    private(set) var handshakes = 0
    /// Test seam: servers skipped because nothing about them had changed.
    private(set) var skips = 0

    init(
        maxHandshakeAge: TimeInterval = MCPWarmSweepLedger.maxHandshakeAge,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.maxHandshakeAge = maxHandshakeAge
        self.clock = clock
    }

    /// Same contract as `refreshAllToolsCaches`: never throws, returns
    /// serverId → tool count or error text, and logs every failure and every
    /// zero-tool result loudly. Skipped servers are reported as "skipped" and
    /// leave `mcp/cache/tools.json` untouched — which is the point: their
    /// catalog bytes are already the bytes a handshake would rewrite.
    @discardableResult
    func sweep(root: URL) async -> [String: String] {
        let dispatcher = SwiftNativeMCPDispatcher(root: root)
        let servers = (try? await dispatcher.listServers()) ?? []
        let manifest = await Self.manifestStamp(dispatcher: dispatcher, root: root)
        let rootKey = root.resolvingSymlinksInPath().path
        let now = clock()

        var report: [String: String] = [:]
        var liveKeys: Set<String> = []
        for server in servers where server.status != "needs_setup" && server.status != "error" {
            let key = "\(rootKey)|\(server.id)"
            liveKeys.insert(key)
            let signature = Signature(manifest: manifest, commandLine: Self.commandLine(server))
            if let mark = marks[key],
               mark.signature == signature,
               now.timeIntervalSince(mark.at) >= 0,
               now.timeIntervalSince(mark.at) < maxHandshakeAge {
                skips += 1
                report[server.id] = "skipped"
                continue
            }
            do {
                let count = try await dispatcher.refreshToolsCache(forServer: server.id)
                handshakes += 1
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
                handshakes += 1
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
    private static func manifestStamp(dispatcher: SwiftNativeMCPDispatcher, root: URL) async -> String {
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

    /// Test seam.
    func _testStats() -> (handshakes: Int, skips: Int, marks: Int) {
        (handshakes, skips, marks.count)
    }

    /// Test seam: fresh-process equivalent.
    func reset() {
        marks.removeAll()
        handshakes = 0
        skips = 0
    }
}

/// Resumes its single waiter on the FIRST `fire()` and ignores every later one.
/// Used to race a bounded deadline against work that may never return.
private actor OneShotLatch {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fire() {
        guard !fired else { return }
        fired = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if fired { c.resume() } else { waiter = c }
        }
    }
}
