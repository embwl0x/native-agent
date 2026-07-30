// Reader protocol + factory for the browser-orchestration STATUS read surface
// (Subsystem #27 — wave 33 W17). The matching WRITE port (run/cancel) lives in
// the companion Browser+Writes.swift (wave 34 W17); this file is the STATUS read
// only.
//
// Mirrors the wave-pattern used by SwarmRuns / KnowledgeGraph / MacAssistantStatus:
//   - a `BrowserStatusReader` protocol with the one read call,
//   - `SwiftNativeBrowserClient` (reads the local files each call),
//   - `makeBrowserClient()` factory.
//
// The SwiftNative reader returns the SAME envelope the daemon GET route does:
//   GET /v1/browser/status -> NativeAgentRuntime.browser_status()
//:
//     {
//       "status": "ready",
//       "profilePath": <str of native_power/browser/profile>,
//       "sourcePath": <str of native_power/browser/sources>,
//       "screenshotPath": <str of native_power/browser/screenshots>,
//       "approvedDomains": <sorted approved_browser_domains()>,
//       "activeRuns": [run for run in runs if status in {running,waiting_approval}],
//       "receiptCount": len(last 20 receipts),
//       "latestReceipt": <newest receipt or null>,
//       "createdAt": now_iso(),
//     }
//
// PORT STATUS (this file = STATUS read only; see Browser+Writes.swift for the
// write port, wave 34 W17). The full cluster picture (§6.96 W33/W34 W17, audit
// re-confirmed §6.220 W40 W19, comment refresh §6.240 W41 W05):
//   GET  /v1/browser/status -> PORTED-DORMANT (this file).
//   POST /v1/browser/cancel (cancel_browser_run)  -> PORTED-DORMANT, FULL
//        (Browser+Writes.swift — self-contained flock'd runs.json R-M-W).
//   POST /v1/browser/run    (run_browser_action)  -> Core owns the canonical
//        operation lifecycle and derived receipts. The app target owns only
//        the approval-gated WKWebView/AppKit effect adapter.
//
// FLOCK SYMMETRY (wave 33 W17): the daemon's run_browser_action /
// cancel_browser_run read-modify-write of native_power/browser/runs.json is
// wrapped in `with file_lock(self.browser_runs_path)`, and
// the Swift write port mirrors it via `withFileLock(runsPath)`
// (Browser+Writes.swift), matching the cross-process sibling-path / LOCK_EX
// convention in PersistenceCore+FileLock.swift <-> the retired daemon. This
// STATUS reader is a PURE read (no write-back), so it does NOT take the lock —
// write_json on the daemon side is atomic (tmp + os.replace) so the read never
// sees a torn file.

import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Protocol

public protocol BrowserStatusReader: Sendable {
    /// GET /v1/browser/status — the full status envelope, or nil when native
    /// status is unavailable.
    func browserStatus() async -> JSONValue?
}

// MARK: - SwiftNative impl

public struct SwiftNativeBrowserClient: BrowserStatusReader {
    /// Absolute path to `<dataRoot>/native_power/browser/runs.json`.
    public let runsPath: URL
    /// Absolute path to `<dataRoot>/native_power/browser/receipts.jsonl`.
    public let receiptsPath: URL
    /// Absolute path to `<dataRoot>/native_power/browser/profile`.
    public let profileDir: URL
    /// Absolute path to `<dataRoot>/native_power/browser/sources`.
    public let sourcesDir: URL
    /// Absolute path to `<dataRoot>/native_power/browser/screenshots`.
    public let screenshotsDir: URL
    /// Absolute path to `<dataRoot>/trust/policy.json` (for approvedDomains).
    public let trustPolicyPath: URL
    // `internal` (not `private`) so the write port in Browser+Writes.swift can
    // reuse the SAME injected core + clock (wave 34 W17).
    let persistence: any PersistenceCoreProtocol
    let now: @Sendable () -> Date

    public init(
        runsPath: URL,
        receiptsPath: URL,
        profileDir: URL,
        sourcesDir: URL,
        screenshotsDir: URL,
        trustPolicyPath: URL,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runsPath = runsPath
        self.receiptsPath = receiptsPath
        self.profileDir = profileDir
        self.sourcesDir = sourcesDir
        self.screenshotsDir = screenshotsDir
        self.trustPolicyPath = trustPolicyPath
        self.persistence = persistence
        self.now = now
    }

    /// Resolve the paths the daemon uses:
    ///   self.browser_runs_path        = root / "native_power" / "browser" / "runs.json"
    ///   self.browser_actions_path     = root / "native_power" / "browser" / "receipts.jsonl"
    ///   self.browser_profile_dir      = root / "native_power" / "browser" / "profile"
    ///   self.browser_sources_dir      = root / "native_power" / "browser" / "sources"
    ///   self.browser_screenshots_dir  = root / "native_power" / "browser" / "screenshots"
    /// where `root` is the data root. PersistenceCore.defaultDataRoot() mirrors
    /// the daemon's data-root resolution.
    public static func defaultClient(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) -> SwiftNativeBrowserClient {
        let browser = dataRoot
            .appendingPathComponent("native_power", isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
        return SwiftNativeBrowserClient(
            runsPath: browser.appendingPathComponent("runs.json"),
            receiptsPath: browser.appendingPathComponent("receipts.jsonl"),
            profileDir: browser.appendingPathComponent("profile", isDirectory: true),
            sourcesDir: browser.appendingPathComponent("sources", isDirectory: true),
            screenshotsDir: browser.appendingPathComponent("screenshots", isDirectory: true),
            trustPolicyPath: dataRoot
                .appendingPathComponent("trust", isDirectory: true)
                .appendingPathComponent("policy.json"),
            persistence: persistence
        )
    }

    public func browserStatus() async -> JSONValue? {
        // runs = read_json(self.browser_runs_path, [])  (default [] on missing/torn)
        let runsRaw = await persistence.readJSON(runsPath, defaultValue: .array([]))
        let runs: [JSONValue]
        if case .array(let arr) = runsRaw { runs = arr } else { runs = [] }

        // active = [run for run in runs if run.get("status") in {"running","waiting_approval"}]
        let activeRuns: [JSONValue] = runs.filter { run in
            guard case .object(let obj) = run, case .string(let s)? = obj["status"] else {
                return false
            }
            return s == "running" || s == "waiting_approval"
        }

        // receipts = list(reversed(tail_jsonl(self.browser_actions_path, 20)))
        // -> last 20 receipt lines, NEWEST FIRST. tail_jsonl returns oldest-first
        // (file order); reversed() makes newest-first.
        //
        // R-W17 (gpt-5.5 review #1): match Python's tail_jsonl DEFAULT scan window
        // of 1 MiB.
        // browser_status calls `tail_jsonl(self.browser_actions_path, 20)` with
        // that default, so a huge receipts.jsonl is tail-scanned, NOT fully read.
        // Passing maxBytes:nil would (a) read the whole file unbounded and (b)
        // diverge on receiptCount/latestReceipt for >1 MiB logs. 1_048_576 is the
        // exact daemon default (and the Swift tailJSONL(_:) convenience default).
        var receipts: [JSONValue] = (try? await persistence.tailJSONL(receiptsPath, limit: 20, maxBytes: 1_048_576)) ?? []
        receipts.reverse()

        let approved = await approvedBrowserDomains()

        // browser_status() emits createdAt = now_iso() (response timestamp).
        return .object([
            "status": .string("ready"),
            "profilePath": .string(profileDir.path),
            "sourcePath": .string(sourcesDir.path),
            "screenshotPath": .string(screenshotsDir.path),
            "approvedDomains": .array(approved.map { .string($0) }),
            // Compatibility key above is historical. It reduces approval risk;
            // it is not a navigation allowlist and does not mint authority.
            "domainPolicy": .string("approval_risk_tiering"),
            "activeRuns": .array(activeRuns),
            "receiptCount": .int(Int64(receipts.count)),
            "latestReceipt": receipts.first ?? .null,
            "createdAt": .string(Self.nowISO(now())),
        ])
    }

    /// Port of `NativeAgentRuntime.approved_browser_domains()` (the retired daemon
    /// L16811): read trust policy, pull `browserPolicy.approvedDomains` (a list),
    /// else the default list; lowercase + strip each; drop empties; return SORTED
    /// (browser_status sorts the set with `sorted(...)`).
    ///
    /// We read `trust/policy.json` directly (not the full normalized trust
    /// policy) because `approved_browser_domains` only consults the saved
    /// `browserPolicy.approvedDomains` key with a fixed fallback list — it does
    /// NOT depend on any normalization the daemon applies elsewhere.
    func approvedBrowserDomains() async -> [String] {
        let defaultDomains = ["example.com", "openai.com", "github.com", "linear.app", "localhost", "127.0.0.1"]
        let raw = await persistence.readJSON(trustPolicyPath, defaultValue: .object([:]))
        var configured: [String]? = nil
        if case .object(let policy) = raw,
           case .object(let browserPolicy)? = policy["browserPolicy"],
           case .array(let domainsRaw)? = browserPolicy["approvedDomains"] {
            // configured is used iff browserPolicy.approvedDomains is a LIST
            // (Python: `configured if isinstance(configured, list) else [...]`).
            //
            // R-W17 (gpt-5.5 review #2): Python does NOT filter to strings — it
            // stringifies EVERY element with `str(domain).lower().strip()`
            //. So a misconfigured `[123, " Foo "]`
            // yields `["123", "foo"]` in Python, not `["foo"]`. Coerce each JSON
            // scalar Python-`str()`-style (int -> "123", double -> Python float
            // repr is not perfectly reproducible but domain lists never carry
            // floats; bool -> "True"/"False"; null -> "None") so receiptCount/
            // approvedDomains match the daemon. Container elements (object/array)
            // are the ONLY case left dropped: Python would emit a dict/list repr,
            // which is never a real domain and never matched by any consumer — so
            // dropping them is strictly safer than emitting "{...}" and cannot
            // affect a real allow-list decision.
            configured = domainsRaw.compactMap { v -> String? in
                switch v {
                case .string(let s): return s
                case .int(let n): return String(n)
                case .double(let d): return String(d)
                case .bool(let b): return b ? "True" : "False"
                case .null: return "None"
                case .object, .array: return nil
                }
            }
        }
        let source = configured ?? defaultDomains
        // {str(domain).lower().strip() for domain in domains if str(domain).strip()}
        // then sorted(...) at the call site (browser_status).
        var deduped = Set<String>()
        for d in source {
            let stripped = d.trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.isEmpty { continue }
            // Python lowercases THEN the set dedups; .lower() then no second strip
            // is needed (already stripped). Use lowercased() to match str.lower().
            deduped.insert(stripped.lowercased())
        }
        return deduped.sorted()
    }

    /// Reproduce the daemon's `now_iso()` shape EXACTLY:
    ///   `datetime.now(timezone.utc).isoformat()`
    /// -> microseconds + `+00:00` offset (NOT `Z`), e.g.
    /// "2026-06-01T17:08:42.123456+00:00". The `createdAt` envelope field is the
    /// RESPONSE timestamp and is non-load-bearing (no consumer parses it), so we
    /// always emit 6 fractional digits rather than special-casing zero-fraction.
    static func nowISO(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return f.string(from: date)
    }
}

// MARK: - Factory

/// Returns the SwiftNative reader. The client is injectable for tests;
/// production callers omit it and get `defaultClient()`.
public func makeBrowserClient(
    client: SwiftNativeBrowserClient? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> any BrowserStatusReader {
    return client ?? SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
}

/// Wave 34 W17: the WRITE-side factory. `SwiftNativeBrowserClient` conforms
/// to both protocols, so the read factory's instance and this one are
/// interchangeable; kept as a distinct entry point so the NativeClient write
/// seam reads cleanly.
public func makeBrowserWriter(
    client: SwiftNativeBrowserClient? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> any BrowserWriter {
    return client ?? SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
}

/// Canonical Browser lifecycle command boundary. WebKit/AppKit callers keep
/// their effect adapters, but never write owner state or receipts themselves.
public func makeBrowserOperationStore(
    client: SwiftNativeBrowserClient? = nil,
    dataRoot: URL = PersistenceCore.defaultDataRoot()
) -> any BrowserOperationCommanding {
    client ?? SwiftNativeBrowserClient.defaultClient(dataRoot: dataRoot)
}
