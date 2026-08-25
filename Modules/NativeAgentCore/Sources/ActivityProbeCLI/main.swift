import ActivityWatch
import Darwin
import Dispatch
import Foundation
import PersistenceCore

#if canImport(AppKit)
import AppKit
#endif

// DEV-ONLY probe for the ambient activity watcher.
// Metadata only: app, bundle id, duration, and — only when the policy says so —
// a window title that has already been through MacScreenViewTextRedaction. No
// AXValue, ever. Zero LLM calls anywhere in capture, rollup, or query. Nothing
// in the app links this executable, and the root Package.swift never names
// ActivityWatch — see docs/build_plans/ambient-activity-watcher.md.

// MARK: - Small helpers

/// Bridges the async store/watcher API into the CLI's synchronous top level.
/// The awaited work runs on the cooperative pool, so this never deadlocks the
/// main thread's run loop.
final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

func blockingAwait<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result!.get()
}

func extractOption(_ name: String, from args: inout [String]) -> String? {
    guard let index = args.firstIndex(of: name) else { return nil }
    guard index + 1 < args.count else {
        args.remove(at: index)
        return nil
    }
    let value = args[index + 1]
    args.removeSubrange(index...(index + 1))
    return value
}

func extractFlag(_ name: String, from args: inout [String]) -> Bool {
    guard let index = args.firstIndex(of: name) else { return false }
    args.remove(at: index)
    return true
}

func resolveDataRoot(_ explicit: String?) -> URL {
    if let explicit, !explicit.isEmpty {
        return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
    }
    return PersistenceCore.defaultDataRoot()
}

func strictDays(_ raw: String?) throws -> Double {
    guard let raw, let days = Double(raw), days.isFinite, days > 0 else {
        throw CLIError.usage("--days needs a positive finite number")
    }
    return days
}

func strictSwitch(_ raw: String, option: String) throws -> Bool {
    switch raw.lowercased() {
    case "on": return true
    case "off": return false
    default: throw CLIError.usage("\(option) must be 'on' or 'off', not '\(raw)'")
    }
}

enum CLIError: Error, LocalizedError {
    case usage(String)
    var errorDescription: String? {
        switch self { case .usage(let message): return message }
    }
}

func formatTimestamp(_ value: Double) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: Date(timeIntervalSince1970: value))
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%02dh%02dm%02ds", total / 3600, (total % 3600) / 60, total % 60)
}

func formatCount(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func usage() {
    print("""
    activity-probe — DEV-ONLY ambient activity watcher (metadata only, zero inference)

    usage: activity-probe <command> [--data-root PATH]

    commands:
      run
                          capture until SIGINT; prints a status line every 30s.
                          Capture must already be enabled by an explicit
                          Trust Center or `policy --enable` decision.
      stats [--days N]    events/hour report over the last N days (default 1)
      dump  [--days N]    print spans over the last N days (default 1)
      rollup [--days N] [--grain hourly|daily] [--tz ID]
                          deterministic rollup answer (top apps + buckets +
                          exemplars), capped at ~50 rows
      policy [--show] [--enable|--disable] [--titles on|off]
             [--browser-titles on|off] [--app-name-only on|off]
             [--exclude BUNDLE] [--include BUNDLE] [--retention-days N]
                          read or edit the privacy policy. --exclude also
                          RETRO-DELETES that bundle's rows (+ WAL checkpoint
                          + VACUUM).
      retention           run the scheduled prune if it is due
      simulate --script FILE.json
      simulate --emit-schema
                          replay a scripted timeline through the REAL state
                          machine and the REAL store, printing the resulting
                          spans as JSON. This is how the span state machine is
                          verified without a window server.
      reconcile           close spans left open by a prior process
      wipe --yes          delete every row
      help                this message
    """)
}

// MARK: - Commands

func commandStats(_ args: [String], dataRoot: URL) throws -> Int32 {
    var args = args
    let days = try strictDays(extractOption("--days", from: &args) ?? "1")
    let now = Date().timeIntervalSince1970
    let from = now - days * 86_400
    let store = try ActivitySpanStore(dataRoot: dataRoot)
    // QUERY-TIME FILTER: the CURRENT policy, not the one in force when the rows
    // were written. Excluding an app today makes yesterday unanswerable.
    let policy = ActivityPolicyStore(dataRoot: dataRoot).load()
    let stats = try blockingAwait { try await store.stats(from: from, to: now, policy: policy) }
    print("activity-probe stats  (\(dataRoot.path))")
    print("  window          : \(formatTimestamp(from)) → \(formatTimestamp(now)) (\(days) d)")
    print("  spans           : \(stats.totalSpans)")
    print("  events          : \(stats.totalEvents)")
    print("  distinct apps   : \(stats.distinctApps)")
    print("  wall clock      : \(formatDuration(stats.wallClockSeconds))")
    print("  EVENTS / HOUR   : \(String(format: "%.2f", stats.eventsPerHour))")
    return 0
}

func commandDump(_ args: [String], dataRoot: URL) throws -> Int32 {
    var args = args
    let days = try strictDays(extractOption("--days", from: &args) ?? "1")
    let now = Date().timeIntervalSince1970
    let from = now - days * 86_400
    let store = try ActivitySpanStore(dataRoot: dataRoot)
    let policy = ActivityPolicyStore(dataRoot: dataRoot).load()
    let total = try blockingAwait {
        try await store.countSpansOverlapping(from: from, to: now, policy: policy)
    }
    let spans = try blockingAwait {
        try await store.spansOverlapping(from: from, to: now, limit: 20_000, policy: policy)
    }
    let truncated = total > spans.count
    let visible = spans
    print("activity-probe dump  (\(formatCount(visible.count)) spans, \(dataRoot.path))")
    if truncated {
        print("  TRUNCATED: \(formatCount(visible.count)) shown; \(formatCount(total - visible.count)) omitted; use a narrower --days window")
    }
    for span in visible {
        let ended = span.endedAt.map(formatTimestamp) ?? "OPEN"
        print(
            "  \(formatTimestamp(span.startedAt)) → \(ended)  "
                + "\(formatDuration(span.duration))  "
                + "events=\(span.eventCount)  "
                + "reason=\(span.closeReason?.rawValue ?? "-")  "
                + "\(span.appName) [\(span.bundleId)]"
                + (span.titleRedacted.map { " — \($0)" } ?? "")
        )
    }
    return 0
}

// MARK: - simulate (the verification seam)

func commandSimulate(_ args: [String], dataRoot: URL) throws -> Int32 {
    var args = args
    if extractFlag("--emit-schema", from: &args) {
        print(ActivityScript.schemaJSON())
        return 0
    }
    guard let path = extractOption("--script", from: &args) else {
        FileHandle.standardError.write(
            Data("error: simulate needs --script FILE.json (or --emit-schema)\n".utf8)
        )
        return 64
    }
    // NEVER simulate into the real data root (gpt-5.5 IMPORTANT, 2026-08-14).
    // `simulate` writes synthetic spans, runs startup reconciliation, and then
    // PRINTS every span in the store — so pointing it at the default root would
    // both corrupt real activity metadata and dump it to stdout. Isolation is
    // mandatory and explicit: pass --data-root, or get a fresh scratch store.
    let isolatedRoot: URL
    if isExplicitDataRoot {
        isolatedRoot = dataRoot
    } else {
        isolatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-simulate-\(UUID().uuidString)", isDirectory: true)
        FileHandle.standardError.write(Data(
            "note: no --data-root given; simulating into a scratch store at \(isolatedRoot.path)\n".utf8
        ))
    }

    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let script = try ActivityScript.parse(data: try Data(contentsOf: url))
    let store = try ActivitySpanStore(dataRoot: isolatedRoot)
    let spans = try blockingAwait { try await ActivitySimulator.replay(script, into: store) }
    print(ActivitySimulator.spansJSON(spans))
    return 0
}

// MARK: - rollup

func commandRollup(_ args: [String], dataRoot: URL) throws -> Int32 {
    var args = args
    let days = try strictDays(extractOption("--days", from: &args) ?? "1")
    let grainName = extractOption("--grain", from: &args)
    let tzName = extractOption("--tz", from: &args)
    let timezone = tzName.flatMap(TimeZone.init(identifier:)) ?? TimeZone.current
    let grain = grainName.flatMap(ActivityRollups.Grain.init(rawValue:))

    let now = Date().timeIntervalSince1970
    let from = now - days * 86_400
    let store = try ActivitySpanStore(dataRoot: dataRoot)
    let policy = ActivityPolicyStore(dataRoot: dataRoot).load()
    let rollups = ActivityRollups(store: store, policy: policy)
    let bundle = try blockingAwait {
        try await rollups.answerBundle(from: from, to: now, timezone: timezone, grain: grain)
    }

    print("activity-probe rollup  (\(timezone.identifier), \(days) d, \(bundle.rowCount) rows)")
    print("  total observed : \(formatDuration(bundle.totalSeconds))")
    print("  top apps:")
    for row in bundle.topApps.rows {
        print("    \(formatDuration(row.seconds))  \(row.appName) [\(row.bundleId)]"
            + "  spans=\(row.spanCount) events=\(row.eventCount)")
    }
    print("  buckets:")
    for bucket in bundle.buckets {
        print("    \(formatTimestamp(bucket.start))  \(formatDuration(bucket.seconds))  "
            + "\(bucket.appName)")
    }
    print("  exemplars:")
    for span in bundle.exemplars {
        print("    \(formatTimestamp(span.startedAt))  \(formatDuration(span.duration))  "
            + "\(span.appName)"
            + (span.titleRedacted.map { " — \($0)" } ?? ""))
    }
    if bundle.truncatedSections.isEmpty {
        print("  truncation     : none")
    } else {
        for note in bundle.truncatedSections { print("  TRUNCATED      : \(note)") }
    }
    return 0
}

// MARK: - policy

func commandPolicy(_ args: [String], dataRoot: URL) throws -> Int32 {
    var args = args
    let policyStore = ActivityPolicyStore(dataRoot: dataRoot)
    var policy = policyStore.load()
    let originalPolicy = policy
    var changed = false
    var purgeTargets: Set<String> = []
    var requestedExclusions: Set<String> = []

    if extractFlag("--enable", from: &args) { policy.captureEnabled = true; changed = true }
    if extractFlag("--disable", from: &args) { policy.captureEnabled = false; changed = true }
    if let value = extractOption("--titles", from: &args) {
        policy.captureTitles = try strictSwitch(value, option: "--titles"); changed = true
    }
    if let value = extractOption("--browser-titles", from: &args) {
        policy.browserTitlesEnabled = try strictSwitch(value, option: "--browser-titles"); changed = true
    }
    if let value = extractOption("--app-name-only", from: &args) {
        policy.appNameOnlyMode = try strictSwitch(value, option: "--app-name-only"); changed = true
    }
    if let value = extractOption("--retention-days", from: &args) {
        guard let days = Int(value), days > 0 else {
            throw CLIError.usage("--retention-days needs a positive whole number")
        }
        policy.retentionDays = days; changed = true
    }
    while let bundle = extractOption("--exclude", from: &args) {
        policy.excludedBundleIDs.insert(bundle)
        requestedExclusions.insert(bundle)
        changed = true
    }
    while let bundle = extractOption("--include", from: &args) {
        policy.excludedBundleIDs.remove(bundle)
        changed = true
    }

    guard args.isEmpty || args == ["--show"] else {
        throw CLIError.usage("unrecognized policy option(s): \(args.joined(separator: " "))")
    }

    // Exclude and include are evaluated as one final policy transaction. A
    // bundle that ends this invocation included must never be purged merely
    // because an earlier argument mentioned --exclude.
    purgeTargets = policy.excludedBundleIDs.subtracting(originalPolicy.excludedBundleIDs)

    if changed {
        try policyStore.save(policy)
        if !purgeTargets.isEmpty {
            // RETRO-DELETE (W5 layer 3): adding an exclusion must make
            // yesterday unanswerable, not just tomorrow.
            let store = try ActivitySpanStore(dataRoot: dataRoot)
            let targets = purgeTargets
            let deleted = try blockingAwait { try await store.purge(bundleIDs: targets) }
            print("retro-deleted \(deleted) row(s) for \(purgeTargets.sorted().joined(separator: ", "))")
        }
    }

    print("activity policy  (\(policyStore.fileURL.path))")
    print("  captureEnabled      : \(policy.captureEnabled)")
    print("  captureTitles       : \(policy.captureTitles)")
    print("  browserTitlesEnabled: \(policy.browserTitlesEnabled)")
    print("  appNameOnlyMode     : \(policy.appNameOnlyMode)")
    print("  retentionDays       : \(policy.retentionDays)")
    print("  excluded (\(policy.effectiveExcludedBundleIDs.count) effective):")
    for bundle in policy.effectiveExcludedBundleIDs.sorted() {
        let locked = ActivityPolicy.alwaysExcludedBundleIDs.contains(bundle) ? "  [always]" : ""
        print("    \(bundle)\(locked)")
    }
    let restored = originalPolicy.excludedBundleIDs.subtracting(policy.excludedBundleIDs)
    if !restored.isEmpty {
        print("  NOTE: including an app permits future capture; already deleted history is not restored.")
    }
    let canceledExclusions = requestedExclusions.subtracting(policy.excludedBundleIDs)
    if !canceledExclusions.isEmpty {
        print("  NOTE: no rows were deleted for \(canceledExclusions.sorted().joined(separator: ", ")); the final policy includes it.")
    }
    return 0
}

func commandRetention(dataRoot: URL) throws -> Int32 {
    let store = try ActivitySpanStore(dataRoot: dataRoot)
    let policy = ActivityPolicyStore(dataRoot: dataRoot).load()
    let runner = ActivityRetentionRunner(dataRoot: dataRoot)
    let outcome = try blockingAwait {
        try await runner.runIfDue(store: store, policy: policy)
    }
    print("retention: ran=\(outcome.ran) deleted=\(outcome.deleted) "
        + "retentionDays=\(policy.retentionDays) nextDue=\(formatTimestamp(outcome.nextDueAt))")
    return 0
}

func commandReconcile(dataRoot: URL) throws -> Int32 {
    let store = try ActivitySpanStore(dataRoot: dataRoot)
    let count = try blockingAwait { try await store.reconcileAbandonedSpans() }
    print("reconciled \(count) abandoned span(s)")
    return 0
}

func commandWipe(_ args: [String], dataRoot: URL) throws -> Int32 {
    var args = args
    guard extractFlag("--yes", from: &args) else {
        FileHandle.standardError.write(Data("error: wipe requires --yes\n".utf8))
        return 64
    }
    let store = try ActivitySpanStore(dataRoot: dataRoot)
    let deleted = try blockingAwait { try await store.wipeAll() }
    print("wiped \(deleted) row(s) from \(dataRoot.path)")
    return 0
}

#if canImport(AppKit)
/// Holder so the SIGINT handler can reach the live watcher.
final class ProbeRuntime: @unchecked Sendable {
    static let shared = ProbeRuntime()
    var watcher: ActivityWatcher?
}

func commandRun(_ args: [String], dataRoot: URL) throws -> Int32 {
    var args = args
    let store = try ActivitySpanStore(dataRoot: dataRoot)
    let policyStore = ActivityPolicyStore(dataRoot: dataRoot)
    let policy = policyStore.load()

    // A probe run cannot grant persistent capture consent. That authority is
    // the explicit policy command / Trust Center transaction, never an
    // incidental diagnostic flag.
    if extractFlag("--enable-capture", from: &args) {
        throw CLIError.usage("run cannot enable capture; use 'policy --enable' first")
    }
    guard policy.captureEnabled else {
        print("activity-probe run  (data root: \(dataRoot.path))")
        print("  capture is DISABLED (captureEnabled=false) — nothing will be recorded.")
        print("  enable it with:  activity-probe policy --enable")
        return 0
    }

    guard AXIsProcessTrusted() else {
        throw CLIError.usage("run requires Accessibility permission; refusing app-change-only capture")
    }

    // Startup reconciliation: spans left open by a prior process are closed at
    // their own last_seen_at, never at "now".
    let reconciled = try blockingAwait { try await store.reconcileAbandonedSpans() }
    let retention = ActivityRetentionRunner(dataRoot: dataRoot)
    let effectivePolicy = policy
    let pruneOutcome = try blockingAwait {
        try await retention.runIfDue(store: store, policy: effectivePolicy)
    }
    print("activity-probe run  (data root: \(dataRoot.path))")
    print("  reconciled \(reconciled) abandoned span(s); "
        + "pruned \(pruneOutcome.deleted) expired row(s) (ran=\(pruneOutcome.ran))")
    print("  titles: captureTitles=\(policy.captureTitles) "
        + "browserTitles=\(policy.browserTitlesEnabled) "
        + "appNameOnly=\(policy.appNameOnlyMode)")

    // The policy FILE is watched too, so `activity-probe policy --disable` in
    // another terminal pauses this run within one tick instead of being ignored
    // until restart (live-run defect, 2026-08-14).
    let watcher = ActivityWatcher(
        store: store,
        policy: policy,
        policySource: ActivityPolicyFileSource(dataRoot: dataRoot)
    )
    ProbeRuntime.shared.watcher = watcher
    watcher.start()
    print("  capturing. metadata only; titles (if enabled) are redacted at the source. ^C to stop.")

    let status = DispatchSource.makeTimerSource(queue: .main)
    status.schedule(deadline: .now() + 30, repeating: 30)
    status.setEventHandler {
        guard let watcher = ProbeRuntime.shared.watcher else { return }
        let snapshot = watcher.status()
        let app = snapshot.isLocked ? "<locked>" : (snapshot.currentApp ?? "-")
        print("  [\(formatTimestamp(Date().timeIntervalSince1970))] "
            + "spans=\(snapshot.spansOpened) events=\(snapshot.eventsRecorded) "
            + "titles=\(snapshot.titlesCaptured) app=\(app)")
    }
    status.resume()

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let onSignal: @Sendable () -> Void = {
        guard let watcher = ProbeRuntime.shared.watcher else { exit(0) }
        ProbeRuntime.shared.watcher = nil
        try? blockingAwait { await watcher.stop() }
        let snapshot = watcher.status()
        print("\n  stopped. spans=\(snapshot.spansOpened) events=\(snapshot.eventsRecorded)")
        exit(0)
    }
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler(handler: onSignal)
    sigint.resume()
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigterm.setEventHandler(handler: onSignal)
    sigterm.resume()

    // NSWorkspace notifications need a live main run loop.
    RunLoop.main.run()
    return 0
}
#endif

// MARK: - Entry point

var arguments = Array(CommandLine.arguments.dropFirst())
let probeDataRootOption = extractOption("--data-root", from: &arguments)
/// Whether the caller explicitly pinned a data root. `simulate` creates a
/// scratch store when this is false; every real-store command refuses to guess.
let isExplicitDataRoot = probeDataRootOption != nil
let probeDataRoot = resolveDataRoot(probeDataRootOption)
let command = arguments.first ?? "help"
let rest = Array(arguments.dropFirst())

do {
    // The probe can print or mutate a private activity history. Make the target
    // explicit for every real-store command; only `simulate` is scratch by
    // default and cannot ever touch the installed history.
    if command != "help", command != "--help", command != "-h", command != "simulate",
       !isExplicitDataRoot {
        throw CLIError.usage("\(command) requires --data-root PATH; refusing the implicit live activity store")
    }
    switch command {
    case "run":
        #if canImport(AppKit)
        exit(try commandRun(rest, dataRoot: probeDataRoot))
        #else
        FileHandle.standardError.write(Data("error: run requires macOS\n".utf8))
        exit(1)
        #endif
    case "stats":
        exit(try commandStats(rest, dataRoot: probeDataRoot))
    case "dump":
        exit(try commandDump(rest, dataRoot: probeDataRoot))
    case "rollup":
        exit(try commandRollup(rest, dataRoot: probeDataRoot))
    case "policy":
        exit(try commandPolicy(rest, dataRoot: probeDataRoot))
    case "retention":
        exit(try commandRetention(dataRoot: probeDataRoot))
    case "simulate":
        exit(try commandSimulate(rest, dataRoot: probeDataRoot))
    case "reconcile":
        exit(try commandReconcile(dataRoot: probeDataRoot))
    case "wipe":
        exit(try commandWipe(rest, dataRoot: probeDataRoot))
    case "help", "--help", "-h":
        usage()
        exit(0)
    default:
        FileHandle.standardError.write(Data("error: unknown command '\(command)'\n".utf8))
        usage()
        exit(64)
    }
} catch let error as CLIError {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
