// Browser status reads atomic owner files without running browser work.
// Receipt summaries retain artifact paths; full captures stay on disk.

import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Protocol

public protocol BrowserStatusReader: Sendable {
    /// GET /v1/browser/status — the full status envelope, or nil when native
    /// status is unavailable.
    func browserStatus() async throws -> JSONValue?
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

    public func browserStatus() async throws -> JSONValue? {
        // Only a missing run feed is empty; malformed content is unavailable.
        let runsRaw = try await persistence.readJSON(runsPath, ifMissing: .array([]))
        guard case .array(let runs) = runsRaw,
              runs.allSatisfy({
                  if case .object(let row) = $0, case .string? = row["status"] { return true }
                  return false
              }) else {
            throw PersistenceCoreError.ioFailure("The browser run feed is malformed.")
        }

        // active = [run for run in runs if run.get("status") in {"running","waiting_approval"}]
        let activeRuns: [JSONValue] = runs.filter { run in
            guard case .object(let obj) = run, case .string(let s)? = obj["status"] else {
                return false
            }
            return s == "running" || s == "waiting_approval"
        }

        // File order is oldest first; keep the bounded tail read.
        let receiptRead = try await persistence.tailJSONLReadReceipt(receiptsPath, limit: 20, maxBytes: 1_048_576)
        guard receiptRead.malformedJSONRowCount == 0,
              receiptRead.rows.allSatisfy({ if case .object = $0 { return true }; return false }),
              receiptRead.physicalRowsScanned > 0 || receiptRead.bytesRead == 0 else {
            throw PersistenceCoreError.ioFailure("The browser receipt feed is malformed.")
        }
        let receipts = receiptRead.rows
        let artifactKeys: Set<String> = ["url", "title", "ipcUrl", "ipcTitle", "httpStatus", "textPath", "htmlPath", "linksPath", "pngPath", "path", "textChars", "linkCount", "captureRetention", "openError", "canceled"]
        let receiptKeys = Set(["id", "transitionId", "domain", "status", "opened", "dryRun", "createdAt", "updatedAt", "completedAt", "verificationStatus", "outcomeKind", "errorCode", "sourceReceipt", "screenshotReceipt"])
            .union(artifactKeys)
        let latestReceipt = receipts.last.map { value -> JSONValue in
            guard case .object(let row) = value else { return .null }
            return .object(row.filter { receiptKeys.contains($0.key) }.mapValues { value in
                guard case .object(let artifact) = value else { return value }
                return .object(artifact.filter { artifactKeys.contains($0.key) })
            })
        } ?? .null

        let approved = try await approvedBrowserDomains()

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
            "receiptPath": .string(receiptsPath.path),
            "latestReceipt": latestReceipt,
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
    func approvedBrowserDomains() async throws -> [String] {
        let defaultDomains = ["example.com", "openai.com", "github.com", "linear.app", "localhost", "127.0.0.1"]
        let raw = try await persistence.readJSON(trustPolicyPath, ifMissing: .object([:]))
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
        NativeTimestampFormat.sixDigitUTCOffset(date)
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
